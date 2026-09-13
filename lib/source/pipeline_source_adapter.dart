import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' show Document;
import 'package:html/parser.dart' show parse;
import 'package:cookie_jar/cookie_jar.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/hls/hls_ad_filter.dart';
import 'package:baka/source/hls/hls_master_playlist.dart';
import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';
import 'package:baka/source/models/episode.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/html_parser.dart';
import 'package:baka/source/webview_adapter.dart';
import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/recipes.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';
import 'package:baka/core/system_proxy.dart';
import 'package:baka/api/bgm.dart';

/// Connects a source rule to the adapter and pipeline host contracts.
class PipelineSourceAdapter extends AdapterBase implements PipelineHost {
  PipelineSourceAdapter(SourceRule rule)
    : rule = Recipes.expand(rule),
      super(rule.name);

  final SourceRule rule;
  static const PipelineInterpreter _interpreter = PipelineInterpreter();
  late final CookieJar _cookieJar = CookieJar();
  WebViewTaskScope? _webViewTaskScope;
  RemoteMediaRedirectResolver? _mediaRedirectResolver;
  Future<void>? _playCookieBarrier;
  Timer? _playbackKeepAliveTimer;
  int _playbackKeepAliveGeneration = 0;
  int? _playbackKeepAliveInFlightGeneration;
  HttpServer? _hlsProxyServer;
  StreamSubscription<HttpRequest>? _hlsProxySubscription;
  List<Uri> _hlsProxyTargets = const [];
  Map<String, String> _hlsProxyHeaders = const {};
  final Map<String, HlsVideoFingerprint?> _hlsProbeCache = {};
  late final _playFeatures = _inspectPlayFeatures(rule.play);
  // 同一页面 HTML 常被连续多个 select/searchList/episodes 步骤解析；
  // 按 identity 缓存最近一次的 DOM，避免重复全量解析（消费方均只读）。
  String? _lastParsedHtml;
  Document? _lastParsedDoc;

  static final RegExp _whitespacePattern = RegExp(r'\s+');
  static final RegExp _hlsUriAttrPattern = RegExp(r'URI="([^"]+)"');

  /// HLS 指纹探测只取分片前缀。实测 16 KB 已足够读到 PAT/PMT 与首个 SPS。
  static const int _hlsProbePrefixBytes = 16 * 1024;

  /// 单个分片指纹探测的超时；探不到按「与正片一致」处理，不阻塞播放。
  static const Duration _hlsProbeTimeout = Duration(seconds: 8);

  /// 前缀取够后主动断连的取消理由。
  static const String _hlsProbeCancelReason = 'HLS 指纹探测已取够前缀';

  /// 指纹缓存条数上限；同一集反复物化时不必重复探测。
  static const int _hlsProbeCacheLimit = 512;

  @override
  String get baseUrl => rule.baseUrl;

  @override
  Map<String, String> get ruleHeaders => rule.headers;

  @override
  bool get allowWebview => rule.useWebview;

  @override
  bool get useSystemProxy => !rule.directConnection;

  @override
  Dio createDio({Map<String, String>? extraHeaders}) {
    final dio = super.createDio(
      extraHeaders: {...rule.headers, ...?extraHeaders},
    );
    dio.interceptors.add(CookieManager(_cookieJar));
    return dio;
  }

  @override
  String get requestUserAgent {
    final ua = (rule.headers['User-Agent'] ?? rule.headers['user-agent'])
        ?.trim();
    return ua != null && ua.isNotEmpty ? ua : super.requestUserAgent;
  }

  @override
  bool get validatesOwnUrls => _playFeatures.validatesWithCookies;

  @override
  Future<MediaReachabilityVerdict> probeMediaReachability(
    String url, {
    Duration? timeout,
    Map<String, String>? headers,
  }) {
    final minimumMs = rule.mediaValidationTimeoutMs;
    final effectiveTimeout = minimumMs > (timeout?.inMilliseconds ?? 0)
        ? Duration(milliseconds: minimumMs)
        : timeout;
    return super.probeMediaReachability(
      url,
      timeout: effectiveTimeout,
      headers: headers,
    );
  }

  @override
  void dispose() {
    _webViewTaskScope?.cancel();
    _mediaRedirectResolver?.close();
    stopPlaybackKeepAlive();
    _dropParseCache();
    super.dispose();
  }

  @override
  Map<String, String> get mediaValidationHeaders {
    final headers = Map<String, String>.from(rule.headers)
      ..removeWhere((_, value) => value.isEmpty);
    return headers.isEmpty ? super.mediaValidationHeaders : headers;
  }

  @override
  Future<List<Series>> search(
    String query, {
    bool enhanceWithBgm = true,
  }) async {
    try {
      final series = await _interpreter.runSearch(rule, this, query);
      if (enhanceWithBgm) {
        var next = 0;
        // Five workers keep requests bounded without waiting for each batch's slowest item.
        await Future.wait(
          List.generate(series.length.clamp(0, 5), (_) async {
            while (next < series.length) {
              final item = series[next++];
              try {
                final subject = await resolveBgmSubject(title: item.name);
                item.image = subject?.imageUrl ?? item.image;
                item.description =
                    subject?.summary ?? item.description ?? '暂无简介';
                item.bgmId = subject?.subjectId ?? item.bgmId;
                item.score = subject?.score ?? item.score;
              } catch (_) {}
            }
          }),
        );
      }
      return series;
    } finally {
      _dropParseCache();
    }
  }

  @override
  Future<PlaybackCatalog> getPlaybackCatalog(String seriesId) => _interpreter
      .runDetail(rule, this, seriesId)
      .then(PlaybackCatalog.fromSources)
      .whenComplete(_dropParseCache);

  @override
  Future<String> getDownloadUrl(String episodeId) {
    final future = !_playFeatures.usesCookies
        ? _interpreter.runPlay(rule, this, episodeId)
        : _withPlayCookieSnapshot(
            () => _interpreter.runPlay(rule, this, episodeId),
          );
    return future.whenComplete(_dropParseCache);
  }

  @override
  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
  }) async {
    if (!_playFeatures.usesDynamicMetadata) {
      return super.resolvePlaybackMedia(
        episodeId,
        skipValidation: skipValidation,
        maxAttempts: maxAttempts,
        reachTimeout: reachTimeout,
      );
    }
    return _withPlayCookieSnapshot(() async {
      final media = await _interpreter.runPlayMedia(rule, this, episodeId);
      if (media.url.isEmpty) {
        return (url: '', httpHeaders: const <String, String>{});
      }
      final headers = await _resolveMediaHeaders(media);
      if (!skipValidation) {
        final verdict = await probeMediaReachability(
          media.url,
          timeout: reachTimeout,
          headers: headers,
        );
        if (verdict == MediaReachabilityVerdict.rejected) {
          debugPrint('$name: 动态媒体被服务器拒绝，丢弃: ${media.url}');
          return (url: '', httpHeaders: const <String, String>{});
        }
        if (verdict == MediaReachabilityVerdict.unknown) {
          debugPrint(
            '$name: 动态媒体结论不确定（超时/临时缺失/网络异常），保留待播放器验证: '
            '${media.url}',
          );
        }
      }
      return (url: media.url, httpHeaders: headers);
    }).whenComplete(_dropParseCache);
  }

  @override
  Future<void> startPlaybackKeepAlive(String mediaUrl) async {
    stopPlaybackKeepAlive();
    final step = _playFeatures.keepAliveStep;
    final mediaUri = Uri.tryParse(mediaUrl);
    if (step == null || mediaUri == null || !mediaUri.hasScheme) return;

    final variables = <String, String>{
      'mediaUrl': mediaUrl,
      ...mediaUri.queryParameters,
    };
    final declaredVariables = step.params['variables'];
    if (declaredVariables is Map) {
      for (final entry in declaredVariables.entries) {
        variables[entry.key.toString()] = PipelineInterpreter.renderTemplate(
          entry.value.toString(),
          (name) => variables[name],
        );
      }
    }

    final urlTemplate = step.str('url')?.trim() ?? '';
    final keepAliveUrl = PipelineInterpreter.renderTemplate(
      urlTemplate,
      (name) => variables[name],
    );
    final keepAliveUri = Uri.tryParse(keepAliveUrl);
    if (keepAliveUri == null || !keepAliveUri.hasScheme) {
      debugPrint('${rule.id}: invalid playback keep-alive URL: $keepAliveUrl');
      return;
    }

    final headers = <String, String>{};
    final rawHeaders = step.params['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = PipelineInterpreter.renderTemplate(
          entry.value.toString(),
          (name) => variables[name],
        );
      }
    }

    final generation = ++_playbackKeepAliveGeneration;
    await _sendPlaybackKeepAlive(
      generation,
      keepAliveUri,
      headers,
      step.str('expectedBody')?.trim(),
    );
    if (generation != _playbackKeepAliveGeneration) return;

    final intervalSeconds = (step.intValue('intervalSeconds') ?? 10)
        .clamp(1, 300)
        .toInt();
    _playbackKeepAliveTimer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => unawaited(
        _sendPlaybackKeepAlive(
          generation,
          keepAliveUri,
          headers,
          step.str('expectedBody')?.trim(),
        ),
      ),
    );
  }

  @override
  Future<({String url, Map<String, String> httpHeaders})> preparePlaybackMedia(
    ({String url, Map<String, String> httpHeaders}) media, {
    bool? filterHlsAds,
  }) async {
    var prepared = media;
    if (_playFeatures.resolvesMediaRedirects) {
      final resolvedUrl =
          await (_mediaRedirectResolver ??= RemoteMediaRedirectResolver(
            useSystemProxy: useSystemProxy,
          )).resolve(media.url, headers: media.httpHeaders);
      if (resolvedUrl != media.url) {
        prepared = (
          url: resolvedUrl,
          httpHeaders: _headersForRedirectTarget(media.httpHeaders),
        );
      }
    }

    final filtersAds =
        filterHlsAds ??
        (_playFeatures.filtersHlsAds ||
            PlaybackSettingsService.getFilterHlsAds());
    if ((!_playFeatures.materializesHls && !filtersAds) ||
        !prepared.url.toLowerCase().contains('.m3u8')) {
      return prepared;
    }
    final manifestUri = Uri.tryParse(prepared.url);
    if (manifestUri == null || !manifestUri.hasScheme) return prepared;

    try {
      var playlist = await _fetchHlsPlaylist(manifestUri, prepared.httpHeaders);
      if (!_playlistLooksFetchable(playlist)) {
        debugPrint(
          '${rule.id}: unable to materialize complete HLS manifest '
          '(HTTP ${playlist.status}, ${playlist.body.length} chars)',
        );
        return prepared;
      }

      // 主清单只有码率变体、没有分片，去广告得先落到一个具体变体上。
      // 这一步固定了码率，所以只在规则显式开启 filterHlsAds 时做。
      if (HlsMasterPlaylist.isMaster(playlist.body)) {
        if (!filtersAds) {
          debugPrint('${rule.id}: HLS 主清单不做物化（未开启 filterHlsAds）');
          return prepared;
        }
        final variant = HlsMasterPlaylist.selectVariant(
          playlist.body,
          playlist.uri,
        );
        if (variant == null) {
          debugPrint('${rule.id}: HLS 主清单无法选定单一变体，放弃去广告');
          return prepared;
        }
        playlist = await _fetchHlsPlaylist(variant.uri, prepared.httpHeaders);
        if (!_playlistLooksFetchable(playlist)) {
          debugPrint(
            '${rule.id}: unable to materialize HLS variant '
            '(HTTP ${playlist.status}, ${playlist.body.length} chars)',
          );
          return prepared;
        }
        debugPrint('${rule.id}: HLS 主清单选定变体 ${variant.label}');
      }

      if (!playlist.body.contains('#EXT-X-ENDLIST')) {
        debugPrint(
          '${rule.id}: unable to materialize complete HLS manifest '
          '(直播清单无 #EXT-X-ENDLIST, ${playlist.body.length} chars)',
        );
        return prepared;
      }

      var body = playlist.body;
      if (filtersAds) {
        final outcome = await HlsAdFilter.apply(
          manifest: body,
          manifestUri: playlist.uri,
          probe: (segmentUri) =>
              _probeHlsSegmentFingerprint(segmentUri, prepared.httpHeaders),
        );
        debugPrint('${rule.id}: HLS 去广告 ${outcome.detail}');
        body = outcome.manifest;
      }

      final proxyUrl = await _startHlsProxy(
        body,
        playlist.uri,
        prepared.httpHeaders,
      );
      return (url: proxyUrl, httpHeaders: const <String, String>{});
    } catch (error) {
      debugPrint('${rule.id}: HLS manifest materialization failed: $error');
      return prepared;
    }
  }

  /// 抓一份 HLS 清单正文。清单地址本身可能 302，分片相对地址要按跳转后的
  /// 地址解析，所以同时返回 [Uri realUri]。
  Future<({String body, Uri uri, int status})> _fetchHlsPlaylist(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await dio.getUri<String>(
      uri,
      options: Options(
        headers: headers,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
        extra: const {SchedulerInterceptor.priorityKey: RequestPriority.play},
      ),
    );
    return (
      body: response.data ?? '',
      uri: response.realUri,
      status: response.statusCode ?? 0,
    );
  }

  static bool _playlistLooksFetchable(
    ({String body, Uri uri, int status}) playlist,
  ) {
    return playlist.status >= 200 &&
        playlist.status < 300 &&
        playlist.body.startsWith('#EXTM3U');
  }

  /// 只取分片前缀（默认 16 KB）读取编码指纹，供 [HlsAdFilter] 判断某个分片
  /// 是否与正片同一次编码。任何失败都返回 null，调用方按「与正片一致」处理。
  Future<HlsVideoFingerprint?> _probeHlsSegmentFingerprint(
    Uri segmentUri,
    Map<String, String> headers,
  ) async {
    final cacheKey = segmentUri.toString();
    if (_hlsProbeCache.containsKey(cacheKey)) {
      return _hlsProbeCache[cacheKey];
    }
    final fingerprint = await _readHlsSegmentFingerprint(segmentUri, headers);
    if (_hlsProbeCache.length >= _hlsProbeCacheLimit) _hlsProbeCache.clear();
    _hlsProbeCache[cacheKey] = fingerprint;
    return fingerprint;
  }

  Future<HlsVideoFingerprint?> _readHlsSegmentFingerprint(
    Uri segmentUri,
    Map<String, String> headers,
  ) {
    final cancelToken = CancelToken();
    Future<HlsVideoFingerprint?> read() async {
      final response = await dio.requestUri<ResponseBody>(
        segmentUri,
        cancelToken: cancelToken,
        options: Options(
          headers: {
            ...headers,
            HttpHeaders.rangeHeader: 'bytes=0-${_hlsProbePrefixBytes - 1}',
          },
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          extra: const {SchedulerInterceptor.priorityKey: RequestPriority.play},
        ),
      );
      final status = response.statusCode ?? 0;
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        return null;
      }
      final stream = response.data?.stream;
      if (stream == null) return null;

      final prefix = BytesBuilder(copy: false);
      try {
        await for (final chunk in stream) {
          prefix.add(chunk);
          // 服务器忽略 Range 时不必把整片读进内存。
          if (prefix.length >= _hlsProbePrefixBytes) break;
        }
      } catch (_) {
        // 主动断连可能让流以错误收尾；已经攒到的前缀仍然可用。
      }
      return MpegTsFingerprint.read(prefix.toBytes());
    }

    return read()
        .timeout(_hlsProbeTimeout, onTimeout: () => null)
        .whenComplete(() {
          // 取够前缀或超时后都断掉连接。取消理由取同一个常量，避免重复取消
          // 触发 CancelToken 的断言。
          cancelToken.cancel(_hlsProbeCancelReason);
        })
        .catchError((Object _) => null);
  }

  static Map<String, String> _headersForRedirectTarget(
    Map<String, String> headers,
  ) {
    return Map<String, String>.from(headers)..removeWhere((name, _) {
      switch (name.toLowerCase()) {
        case 'authorization':
        case 'cookie':
        case 'host':
        case 'origin':
        case 'referer':
          return true;
        default:
          return false;
      }
    });
  }

  @override
  void stopPlaybackKeepAlive() {
    _playbackKeepAliveGeneration++;
    _playbackKeepAliveTimer?.cancel();
    _playbackKeepAliveTimer = null;
    unawaited(_stopHlsProxy());
  }

  Future<String> _startHlsProxy(
    String body,
    Uri manifestUri,
    Map<String, String> headers,
  ) async {
    await _stopHlsProxy();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final secret = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final baseUrl = 'http://${server.address.address}:${server.port}/$secret';
    final targetIds = <Uri, int>{};

    String proxyUrlFor(Uri target) {
      final id = targetIds.putIfAbsent(target, () => targetIds.length);
      return '$baseUrl/media/${id.toRadixString(36)}';
    }

    final materialized = _materializeHlsManifest(
      body,
      manifestUri,
      proxyUrlFor,
    );
    if (!materialized.contains('#EXTM3U') ||
        !materialized.contains('#EXT-X-ENDLIST')) {
      await server.close(force: true);
      throw const FormatException('incomplete VOD manifest');
    }

    _hlsProxyServer = server;
    _hlsProxyTargets = targetIds.keys.toList(growable: false);
    _hlsProxyHeaders = Map<String, String>.unmodifiable(headers);
    _hlsProxySubscription = server.listen(
      (request) =>
          unawaited(_handleHlsProxyRequest(request, secret, materialized)),
    );
    return '$baseUrl/manifest.m3u8';
  }

  Future<void> _handleHlsProxyRequest(
    HttpRequest request,
    String secret,
    String manifest,
  ) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (segments.length == 2 &&
          segments[0] == secret &&
          segments[1] == 'manifest.m3u8') {
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
          charset: 'utf-8',
        );
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.write(manifest);
        await response.close();
        return;
      }

      if (segments.length != 3 ||
          segments[0] != secret ||
          segments[1] != 'media') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final id = int.tryParse(segments[2], radix: 36);
      if (id == null || id < 0 || id >= _hlsProxyTargets.length) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final headers = Map<String, String>.from(_hlsProxyHeaders);
      for (final name in const [
        HttpHeaders.rangeHeader,
        HttpHeaders.ifRangeHeader,
        HttpHeaders.ifModifiedSinceHeader,
        HttpHeaders.ifNoneMatchHeader,
      ]) {
        final value = request.headers.value(name);
        if (value != null && value.isNotEmpty) headers[name] = value;
      }
      final remote = await dio.requestUri<ResponseBody>(
        _hlsProxyTargets[id],
        options: Options(
          method: request.method == 'HEAD' ? 'HEAD' : 'GET',
          headers: headers,
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
        ),
      );
      response.statusCode = remote.statusCode ?? HttpStatus.badGateway;
      for (final name in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.cacheControlHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = remote.headers.value(name);
        if (value != null && value.isNotEmpty) {
          response.headers.set(name, value);
        }
      }
      final stream = remote.data?.stream;
      if (request.method != 'HEAD' && stream != null) {
        await response.addStream(stream);
      }
      await response.close();
    } catch (error) {
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
      debugPrint('${rule.id}: HLS proxy request failed: $error');
    }
  }

  Future<void> _stopHlsProxy() async {
    final subscription = _hlsProxySubscription;
    final server = _hlsProxyServer;
    _hlsProxySubscription = null;
    _hlsProxyServer = null;
    _hlsProxyTargets = const [];
    _hlsProxyHeaders = const {};
    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await server?.close(force: true);
    } catch (_) {}
  }

  static String _materializeHlsManifest(
    String body,
    Uri manifestUri,
    String Function(Uri target) proxyUrlFor,
  ) {
    return body
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return '';
          if (!trimmed.startsWith('#')) {
            return proxyUrlFor(manifestUri.resolve(trimmed));
          }
          return line.replaceAllMapped(_hlsUriAttrPattern, (match) {
            final resolved = manifestUri.resolve(match.group(1)!);
            return 'URI="${proxyUrlFor(resolved)}"';
          });
        })
        .join('\n');
  }

  Future<void> _sendPlaybackKeepAlive(
    int generation,
    Uri url,
    Map<String, String> headers,
    String? expectedBody,
  ) async {
    if (generation != _playbackKeepAliveGeneration ||
        _playbackKeepAliveInFlightGeneration == generation) {
      return;
    }
    _playbackKeepAliveInFlightGeneration = generation;
    try {
      final response = await dio.getUri<String>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      if (generation != _playbackKeepAliveGeneration) return;
      final status = response.statusCode ?? 0;
      final body = response.data?.trim() ?? '';
      final validBody =
          expectedBody == null || expectedBody.isEmpty || body == expectedBody;
      if (status < 200 || status >= 300 || !validBody) {
        debugPrint(
          '${rule.id}: playback keep-alive rejected '
          '(HTTP $status, body: $body)',
        );
      }
    } catch (error) {
      if (generation == _playbackKeepAliveGeneration) {
        debugPrint('${rule.id}: playback keep-alive failed: $error');
      }
    } finally {
      if (_playbackKeepAliveInFlightGeneration == generation) {
        _playbackKeepAliveInFlightGeneration = null;
      }
    }
  }

  Future<T> _withPlayCookieSnapshot<T>(Future<T> Function() action) async {
    if (!_playFeatures.usesCookies) return action();
    final previous = _playCookieBarrier ?? Future<void>.value();
    final release = Completer<void>();
    _playCookieBarrier = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<Map<String, String>> _resolveMediaHeaders(
    PipelinePlayResult media,
  ) async {
    final headers = media.mediaHeaders.isEmpty
        ? Map<String, String>.from(rule.headers)
        : Map<String, String>.from(media.mediaHeaders);
    headers.removeWhere((_, value) => value.isEmpty);
    if (headers.isEmpty) headers.addAll(super.mediaValidationHeaders);
    if (VideoUrlExtractor.isSignedCdnUrl(media.url)) {
      headers.removeWhere((key, _) => key.toLowerCase() == 'referer');
    }
    if (media.cookieNames.isEmpty && media.cookiePrefixes.isEmpty) {
      return headers;
    }

    try {
      final exactNames = media.cookieNames.toSet();
      final prefixes = media.cookiePrefixes.where((p) => p.isNotEmpty).toList();
      final cookies = await _cookieJar.loadForRequest(Uri.parse(media.url));
      final filtered = <String, String>{};
      for (final cookie in cookies) {
        final allowed =
            exactNames.contains(cookie.name) ||
            prefixes.any((p) => cookie.name.startsWith(p));
        if (allowed && cookie.value.isNotEmpty) {
          filtered[cookie.name] = cookie.value;
        }
      }
      final cookieHeader = filtered.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
      if (cookieHeader.isNotEmpty) {
        final cookieKey = headers.keys.cast<String?>().firstWhere(
          (key) => key?.toLowerCase() == 'cookie',
          orElse: () => null,
        );
        if (cookieKey == null || (headers[cookieKey] ?? '').trim().isEmpty) {
          headers['Cookie'] = cookieHeader;
        } else {
          headers[cookieKey] = '${headers[cookieKey]}; $cookieHeader';
        }
      }
    } catch (_) {}
    return headers;
  }

  static ({
    bool usesDynamicMetadata,
    bool usesCookies,
    bool validatesWithCookies,
    bool materializesHls,
    bool filtersHlsAds,
    bool resolvesMediaRedirects,
    bool followsEmbeddedPlayer,
    PipelineStep? keepAliveStep,
  })
  _inspectPlayFeatures(List<PipelineStep> steps) {
    var usesDynamicMetadata = false;
    var usesCookies = false;
    var validatesWithCookies = false;
    var materializesHls = false;
    var filtersHlsAds = false;
    var resolvesMediaRedirects = false;
    var followsEmbeddedPlayer = false;
    PipelineStep? keepAliveStep;

    void inspect(List<PipelineStep> current) {
      for (final step in current) {
        if (step.op == 'setMediaHeaders' || step.op == 'anime1Play') {
          usesDynamicMetadata = true;
        }
        if (step.op == 'anime1Play') usesCookies = true;
        validatesWithCookies |= step.flag('validateWithCookies');
        materializesHls |= step.flag('materializeHls');
        filtersHlsAds |= step.flag('filterHlsAds');
        resolvesMediaRedirects |= step.flag('resolveMediaRedirects');
        followsEmbeddedPlayer |= step.flag('followEmbeddedPlayer');
        if (keepAliveStep == null && step.flag('playbackKeepAlive')) {
          keepAliveStep = step;
        }
        for (final branch in step.branches) {
          inspect(branch);
        }
      }
    }

    inspect(steps);
    return (
      usesDynamicMetadata: usesDynamicMetadata,
      usesCookies: usesCookies,
      validatesWithCookies: validatesWithCookies,
      materializesHls: materializesHls,
      filtersHlsAds: filtersHlsAds,
      resolvesMediaRedirects: resolvesMediaRedirects,
      followsEmbeddedPlayer: followsEmbeddedPlayer,
      keepAliveStep: keepAliveStep,
    );
  }

  @override
  String toAbsolute(String url, String base) =>
      VideoUrlExtractor.toAbsolute(url.trim(), base.isEmpty ? baseUrl : base);

  @override
  String normalizeUrl(String url, String pageUrl) =>
      VideoUrlExtractor.normalizeResolvedUrl(
        url,
        pageUrl.isEmpty ? baseUrl : pageUrl,
        preserveMagnet: true,
      );

  @override
  bool isPlayable(String url) => VideoUrlExtractor.isPlayable(url);

  @override
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    RequestPriority priority = RequestPriority.search,
  }) async {
    try {
      final resp = await dio.request(
        url,
        data: body,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          contentType: contentType == 'form'
              ? Headers.formUrlEncodedContentType
              : contentType,
          headers: {
            ...rule.headers,
            if (referer != null && referer.isNotEmpty) 'Referer': referer,
            ...?headers,
          },
          extra: {SchedulerInterceptor.priorityKey: priority},
        ),
      );
      return resp.data?.toString() ?? '';
    } on DioException catch (e) {
      debugPrint(
        '$name: fetch 失败 $url: ${e.message ?? e.type.name}, error: ${e.error}, resp: ${e.response?.statusCode}',
      );
      return '';
    }
  }

  @override
  List<Series> parseSearchList(
    String html, {
    required List<String> selectors,
    String? detailPattern,
  }) {
    if (html.trim().isEmpty) return const [];
    return HtmlParser.parseSearchResults(
      _parseCached(html),
      baseUrl: baseUrl,
      selectors: selectors,
      detailPattern: detailPattern,
    );
  }

  Document _parseCached(String html) {
    if (!identical(html, _lastParsedHtml)) {
      _lastParsedDoc = parse(html);
      _lastParsedHtml = html;
    }
    return _lastParsedDoc!;
  }

  void _dropParseCache() {
    _lastParsedHtml = null;
    _lastParsedDoc = null;
  }

  @override
  List<Series> parseSearchListXPath(
    String html, {
    required String listXPath,
    required String nameXPath,
    required String linkXPath,
  }) {
    final results = <Series>[];
    try {
      final docEl = _parseCached(html).documentElement;
      if (docEl == null) return results;
      final nodes = docEl.queryXPath(listXPath).nodes;
      for (final node in nodes) {
        final linkNode = linkXPath.isEmpty
            ? node
            : node.queryXPath(linkXPath).node;
        final href = linkNode?.attributes['href'] ?? '';
        if (href.isEmpty) continue;
        final name =
            (nameXPath.isEmpty
                ? node.node.text
                : node.queryXPath(nameXPath).node?.text) ??
            '';
        results.add(
          Series(
            toAbsolute(href, baseUrl),
            name.trim().isEmpty ? '未知标题' : name.trim(),
          ),
        );
      }
    } catch (e) {
      debugPrint('$name: XPath 搜索解析失败: $e');
    }
    return results;
  }

  @override
  List<Source> parseEpisodes(
    String html, {
    required List<String> listSelectors,
    List<String>? tabSelectors,
  }) {
    if (html.trim().isEmpty) return const [];
    return HtmlParser.parseSources(
      _parseCached(html),
      baseUrl: baseUrl,
      listSelectors: listSelectors.isEmpty ? null : listSelectors,
      tabSelectors: tabSelectors,
    );
  }

  @override
  List<Source> parseEpisodesXPath(
    String html, {
    required String roadsXPath,
    required String itemsXPath,
  }) {
    final sources = <Source>[];
    try {
      final docEl = _parseCached(html).documentElement;
      if (docEl == null) return sources;
      final roads = docEl.queryXPath(roadsXPath).nodes;
      var count = 1;
      for (final road in roads) {
        final items = road.queryXPath(itemsXPath).nodes;
        final episodes = <Episode>[];
        for (var i = 0; i < items.length; i++) {
          final href = items[i].attributes['href'] ?? '';
          if (href.isEmpty) continue;
          var name =
              items[i].node.text?.replaceAll(_whitespacePattern, '') ?? '';
          if (name.isEmpty) name = '第${i + 1}集';
          episodes.add(Episode(toAbsolute(href, baseUrl), i, name));
        }
        if (episodes.isNotEmpty) {
          sources.add(Source(episodes, '播放列表$count'));
          count++;
        }
      }
    } catch (e) {
      debugPrint('$name: XPath 剧集解析失败: $e');
    }
    return sources;
  }

  @override
  String extractVideoUrl(String content, String pageUrl) =>
      VideoUrlExtractor.extractBest(
        content,
        pageUrl.isEmpty ? baseUrl : pageUrl,
      );

  @override
  String? selectAttr(String html, String selector, String attr) {
    try {
      final element = _parseCached(html).querySelector(selector);
      if (element == null) return null;
      return attr == 'text' ? element.text.trim() : element.attributes[attr];
    } catch (_) {
      return null;
    }
  }

  @override
  List<String> selectAll(String html, String selector, String attr) {
    try {
      return _parseCached(html)
          .querySelectorAll(selector)
          .map(
            (e) => attr == 'text' ? e.text.trim() : (e.attributes[attr] ?? ''),
          )
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String> renderWithWebview(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 1),
  }) async {
    if (!allowWebview) return '';
    try {
      final (html, cookies) = await WebViewAdapter.getPageContentWithCookies(
        url,
        isReady: isReady,
        timeout: timeout,
        settleDelay: settleDelay,
        userAgent: requestUserAgent,
        taskScope: _webViewTaskScope ??= WebViewTaskScope(),
      );
      if (cookies.isNotEmpty) await _storeWebViewCookies(url, cookies);
      return html;
    } catch (e) {
      debugPrint('$name: WebView 渲染失败: $e');
      return '';
    }
  }

  Future<void> _storeWebViewCookies(String url, String cookieString) async {
    final raw = cookieString.trim();
    if (raw.isEmpty) return;
    try {
      final uri = Uri.parse(url);
      final cookies = <Cookie>[];
      for (final part in raw.split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final name = part.substring(0, eq).trim();
        final value = part.substring(eq + 1).trim();
        if (name.isEmpty) continue;
        cookies.add(Cookie(name, value));
      }
      if (cookies.isNotEmpty) await _cookieJar.saveFromResponse(uri, cookies);
    } catch (e) {
      debugPrint('$name: WebView Cookie 同步失败: $e');
    }
  }

  @override
  Future<String> sniffWithWebview(String url) async {
    try {
      final cookieHeader = rule.headers.entries
          .where((entry) => entry.key.toLowerCase() == 'cookie')
          .map((entry) => entry.value.trim())
          .firstWhere((value) => value.isNotEmpty, orElse: () => '');
      return await WebViewAdapter.extractVideoUrl(
            url,
            userAgent: requestUserAgent,
            cookieHeader: cookieHeader.isEmpty ? null : cookieHeader,
            followEmbeddedPlayer: _playFeatures.followsEmbeddedPlayer,
            taskScope: _webViewTaskScope ??= WebViewTaskScope(),
          ) ??
          '';
    } catch (e) {
      debugPrint('$name: WebView 嗅探失败: $e');
      return '';
    }
  }
}

/// Resolves redirect-only media entry points before handing them to libmpv.
class RemoteMediaRedirectResolver {
  static const _maxRedirects = 5;
  static const _requestTimeout = Duration(seconds: 20);
  static const _hopByHop = {
    'connection',
    'content-length',
    'host',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };

  RemoteMediaRedirectResolver({bool useSystemProxy = true})
    : _client =
          (useSystemProxy
                ? SystemProxyService.createHttpClient()
                : SystemProxyService.createDirectHttpClient())
            ..connectionTimeout = _requestTimeout
            ..idleTimeout = const Duration(seconds: 15)
            ..userAgent = 'Baka Media Resolver';

  final HttpClient _client;

  Future<String> resolve(
    String remoteUrl, {
    Map<String, String> headers = const {},
  }) async {
    final original = Uri.tryParse(remoteUrl);
    if (original == null ||
        (original.scheme != 'http' && original.scheme != 'https')) {
      return remoteUrl;
    }

    Map<String, String>? safeHeaders;
    if (headers.isNotEmpty) {
      safeHeaders = <String, String>{};
      for (final entry in headers.entries) {
        if (!_hopByHop.contains(entry.key.toLowerCase())) {
          safeHeaders[entry.key] = entry.value;
        }
      }
    }

    var current = original;
    try {
      for (var hop = 0; hop <= _maxRedirects; hop++) {
        final request = await _client.headUrl(current).timeout(_requestTimeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

        if (safeHeaders != null && _sameAuthority(current, original)) {
          safeHeaders.forEach(request.headers.set);
        }

        final response = await request.close().timeout(_requestTimeout);
        final location = response.headers.value(HttpHeaders.locationHeader);
        final status = response.statusCode;
        await response.drain<void>().timeout(_requestTimeout);

        if (location != null &&
            location.isNotEmpty &&
            _isRedirectStatus(status)) {
          current = current.resolve(location);
          continue;
        }

        if (status >= 200 && status < 400) {
          if (current != original) {
            debugPrint(
              '[RemoteMediaResolver] ${original.host} -> '
              '${current.host}:${current.port}',
            );
          }
          return current.toString();
        }
        debugPrint('[RemoteMediaResolver] HTTP $status for ${current.host}');
        return remoteUrl;
      }
      debugPrint(
        '[RemoteMediaResolver] too many redirects for ${original.host}',
      );
    } catch (error) {
      debugPrint('[RemoteMediaResolver] ${original.host} failed: $error');
    }
    return remoteUrl;
  }

  static bool _isRedirectStatus(int status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == HttpStatus.permanentRedirect;

  static bool _sameAuthority(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  void close() => _client.close(force: true);
}
