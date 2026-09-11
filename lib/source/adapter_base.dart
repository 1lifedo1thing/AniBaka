import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/source/webview_adapter.dart';
import 'package:baka/core/system_proxy.dart';
import 'package:baka/instance.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';

/// 直链可达性探测的结论。
enum MediaReachabilityVerdict {
  reachable,
  rejected,
  unknown,
}

/// Base class for all video source adapters.
abstract class AdapterBase {
  final String name;

  String get baseUrl;

  Dio? _dio;
  AdapterBase(this.name);

  /// Signed media sources can opt out when their token and playback requests
  /// must use the same direct network exit.
  bool get useSystemProxy => true;

  Dio get dio => _dio ??= createDio();

  Dio createDio({Map<String, String>? extraHeaders}) {
    final dio = Dio(
      BaseOptions(
        headers: {
          'User-Agent': defaultUserAgent,
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          'Connection': 'keep-alive',
          ...?extraHeaders,
        },
        followRedirects: true,
        maxRedirects: 5,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        validateStatus: (status) => status != null && status < 600,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: useSystemProxy
          ? SystemProxyService.createHttpClient
          : SystemProxyService.createDirectHttpClient,
    );
    dio.interceptors.add(SchedulerInterceptor());
    dio.interceptors.add(RetryInterceptor(dio));
    return dio;
  }

  static const String defaultUserAgent = WebViewAdapter.desktopUserAgent;
  String get requestUserAgent => defaultUserAgent;

  /// Releases source-scoped background work when its owning service closes.
  void dispose() {
    _dio?.close(force: true);
    _dio = null;
  }

  Future<List<Series>> search(String query, {bool enhanceWithBgm = true});
  Future<PlaybackCatalog> getPlaybackCatalog(String seriesId);

  Future<String> getDownloadUrl(String episodeId);

  static const Duration _cacheTtl = Duration(minutes: 10);
  static const int _cacheLimit = 128;
  static final Map<String, ({String url, int expiresAt})> _cache = {};

  /// 可达性探测结果缓存（含负缓存），避免同一死链在匹配/换线时反复拖超时。
  static const Duration _reachCacheTtl = Duration(minutes: 3);
  static const Duration _reachNegCacheTtl = Duration(minutes: 8);
  static const int _reachCacheLimit = 256;
  static final Map<String, ({bool ok, int expiresAt, int timeoutMs})>
  _reachCache = {};

  bool get validatesOwnUrls => false;

  Map<String, String> get mediaValidationHeaders => const {
    'User-Agent': defaultUserAgent,
    'Accept': '*/*',
  };

  Future<String> resolveDownloadUrl(
    String episodeId, {
    bool forceRefresh = false,
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
  }) async {
    final key = '$name|$episodeId';
    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null) {
        if (cached.expiresAt > DateTime.now().millisecondsSinceEpoch) {
          return cached.url;
        }
        _cache.remove(key);
      }
    }

    final url = await _getDownloadUrlWithRetry(
      episodeId,
      maxAttempts: maxAttempts,
    );
    if (url.isEmpty) {
      debugPrint('$name: resolveDownloadUrl 解析结果为空');
      return '';
    }

    debugPrint(
      '$name: resolveDownloadUrl 得到URL: $url, isSignedCdn=${VideoUrlExtractor.isSignedCdnUrl(url)}, validatesOwnUrls=$validatesOwnUrls',
    );
    if (!skipValidation && !validatesOwnUrls) {
      final verdict = await probeMediaReachability(url, timeout: reachTimeout);
      if (verdict == MediaReachabilityVerdict.rejected) {
        debugPrint('$name: 直链被服务器拒绝，丢弃: $url');
        return '';
      }
      if (verdict == MediaReachabilityVerdict.unknown) {
        debugPrint(
          '$name: 直链结论不确定（超时/临时缺失/网络异常），保留待播放器验证: $url',
        );
      }
    }

    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    _cache[key] = (
      url: url,
      expiresAt:
          DateTime.now().millisecondsSinceEpoch + _cacheTtl.inMilliseconds,
    );
    return url;
  }

  /// 探测媒体 URL 是否真正可拉取（自动匹配认领前必须通过）。
  Future<bool> isPlaybackUrlReachable(String url, {Duration? timeout}) async =>
      await probeMediaReachability(url, timeout: timeout) !=
      MediaReachabilityVerdict.rejected;

  /// 探测结论版的可达性检查，供需要区分「被拒」与「未知」的调用方使用。
  @protected
  Future<MediaReachabilityVerdict> probeMediaReachability(
    String url, {
    Duration? timeout,
  }) async {
    final value = url.trim();
    if (value.isEmpty) return MediaReachabilityVerdict.rejected;
    final lower = value.toLowerCase();
    if (lower.startsWith('magnet:') || lower.contains('.torrent')) {
      return MediaReachabilityVerdict.reachable;
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return MediaReachabilityVerdict.rejected;
    }
    if (validatesOwnUrls) return MediaReachabilityVerdict.reachable;

    final probeTimeoutMs = timeout?.inMilliseconds ?? 0;
    final cached = _reachCache[value];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (cached != null) {
      if (cached.expiresAt > now &&
          (cached.ok || probeTimeoutMs <= cached.timeoutMs)) {
        return cached.ok
            ? MediaReachabilityVerdict.reachable
            : MediaReachabilityVerdict.rejected;
      }
      _reachCache.remove(value);
    }

    final verdict = await _probeDirectUrl(value, timeout: timeout);
    // 只缓存明确结论。「未知」一旦被负缓存，同一个可用地址会在之后数分钟
    // 里持续被误杀（负缓存 TTL 是 8 分钟）；临时媒体地址随时可能被重新
    // 生成，同样不做负缓存。
    final cacheable = switch (verdict) {
      MediaReachabilityVerdict.reachable => true,
      MediaReachabilityVerdict.unknown => false,
      MediaReachabilityVerdict.rejected =>
        !VideoUrlExtractor.isOnDemandMediaPath(value),
    };
    if (cacheable) {
      _putReachCache(
        value,
        verdict == MediaReachabilityVerdict.reachable,
        probeTimeoutMs,
      );
    }
    return verdict;
  }

  static void _putReachCache(String url, bool ok, int timeoutMs) {
    if (_reachCache.length >= _reachCacheLimit) {
      _reachCache.remove(_reachCache.keys.first);
    }
    final ttl = ok ? _reachCacheTtl : _reachNegCacheTtl;
    _reachCache[url] = (
      ok: ok,
      expiresAt: DateTime.now().millisecondsSinceEpoch + ttl.inMilliseconds,
      timeoutMs: timeoutMs,
    );
  }

  Future<String> _getDownloadUrlWithRetry(
    String episodeId, {
    int maxAttempts = 2,
  }) async {
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        return await getDownloadUrl(episodeId);
      } catch (e) {
        lastError = e;
      }
    }
    debugPrint('$name: 直链解析失败: $lastError');
    return '';
  }

  static Dio _createValidationDio(bool useSystemProxy) => Dio(
    BaseOptions(
      followRedirects: true,
      maxRedirects: 3,
      receiveTimeout: const Duration(milliseconds: 2500),
      sendTimeout: const Duration(milliseconds: 2000),
      validateStatus: (_) => true,
    ),
  )..httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: useSystemProxy
        ? SystemProxyService.createHttpClient
        : SystemProxyService.createDirectHttpClient,
  );

  /// 探测用的共享客户端。路由必须和规则本身一致：声明 `directConnection`
  /// 的源若被拿去做代理探测，会因出口不同被判成死链。
  static final Dio _validationDio = _createValidationDio(true);
  static final Dio _validationDirectDio = _createValidationDio(false);

  Dio get _probeDio => useSystemProxy ? _validationDio : _validationDirectDio;

  /// 服务器明确表示「没有/不许」的状态，可直接判死链。
  static const Set<int> _rejectedStatuses = {
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
    HttpStatus.notFound,
    HttpStatus.gone,
    HttpStatus.unavailableForLegalReasons,
    HttpStatus.internalServerError,
    HttpStatus.badGateway,
    HttpStatus.serviceUnavailable,
    HttpStatus.gatewayTimeout,
  };

  static const Set<int> _headFallbackStatuses = {
    ..._rejectedStatuses,
    HttpStatus.methodNotAllowed,
  };

  /// 「现在没有」类状态：内容可能只是尚未生成、刚被回收或后端抖动。
  /// 命中这些状态时，临时媒体地址只记为「未知」，交给播放器验证。
  static const Set<int> _transientRejectStatuses = {
    HttpStatus.notFound,
    HttpStatus.gone,
    HttpStatus.internalServerError,
    HttpStatus.badGateway,
    HttpStatus.serviceUnavailable,
    HttpStatus.gatewayTimeout,
  };

  /// 「凭据没对上」类状态：临时媒体地址带 token / 绑定会话，裸探测
  /// （HEAD、`bytes=0-0` 这类请求）与播放器的完整请求并非同一种请求，
  /// 401/403 往往只说明探测这一次没被放行。
  static const Set<int> _authRejectStatuses = {
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
  };

  /// 临时媒体地址上不足以判死链的状态。
  static const Set<int> _ephemeralRejectStatuses = {
    ..._transientRejectStatuses,
    ..._authRejectStatuses,
  };

  /// 临时媒体地址的「保留待播放器验证」判定：只有明确说明「现在没有」
  /// 或「这次没放行」的状态才放行；网页/JSON 形态的拒绝页仍判死链。
  static bool _shouldKeepEphemeralOnReject(int statusCode, String? contentType) {
    if (!_ephemeralRejectStatuses.contains(statusCode)) return false;
    if (contentType != null && _htmlLikeContentType.hasMatch(contentType)) {
      // 403 也可能是 WAF 拦截页：拿到网页就说明这不是媒体响应。
      if (_authRejectStatuses.contains(statusCode)) return false;
    }
    return true;
  }

  static final RegExp _htmlLikeContentType = RegExp(
    r'^\s*(?:text/html|application/xhtml|text/xml|application/xml|'
    r'application/json|image/)',
    caseSensitive: false,
  );

  static Future<Response<dynamic>> _runValidationProbe(
    Future<Response<dynamic>> Function(CancelToken cancelToken) send,
    Duration timeout,
  ) {
    final cancelToken = CancelToken();
    return send(cancelToken).timeout(
      timeout,
      onTimeout: () {
        cancelToken.cancel('media reachability probe timed out');
        throw TimeoutException('media reachability probe timed out', timeout);
      },
    );
  }

  Future<MediaReachabilityVerdict> _probeDirectUrl(
    String url, {
    Duration? timeout,
  }) async {
    if (!url.startsWith('http')) return MediaReachabilityVerdict.rejected;
    if (VideoUrlExtractor.looksLikeNonMedia(url)) {
      return MediaReachabilityVerdict.rejected;
    }
    if (VideoUrlExtractor.isSignedCdnUrl(url)) {
      return MediaReachabilityVerdict.reachable;
    }

    // 竞速默认更狠：手机 ~1.8s，TV ~2.2s；调用方可再收紧。
    final probeTimeout =
        timeout ??
        (Instances.isTV
            ? const Duration(milliseconds: 2200)
            : const Duration(milliseconds: 1800));
    final client = _probeDio;

    try {
      final headers = mediaValidationHeaders;
      final isHls = VideoUrlExtractor.isHlsUrl(url);

      if (isHls) {
        final resp = await _runValidationProbe(
          (cancelToken) => client.get(
            url,
            cancelToken: cancelToken,
            options: Options(
              headers: {
                ...headers,
                'Range': 'bytes=0-2047',
                'Accept':
                    'application/vnd.apple.mpegurl,application/x-mpegURL,*/*',
              },
              responseType: ResponseType.plain,
              receiveTimeout: probeTimeout,
              sendTimeout: probeTimeout,
              extra: const {'__reach_probe': true},
            ),
          ),
          probeTimeout,
        );
        if (_playlistLooksAlive(resp.statusCode, resp.data?.toString())) {
          return MediaReachabilityVerdict.reachable;
        }
        // 临时媒体上的播放列表同样可能尚未生成或本次未放行：保留待播放器验证。
        if (VideoUrlExtractor.isOnDemandMediaPath(url) &&
            _shouldKeepEphemeralOnReject(
              resp.statusCode ?? 0,
              resp.headers.value(HttpHeaders.contentTypeHeader),
            )) {
          return MediaReachabilityVerdict.unknown;
        }
        return MediaReachabilityVerdict.rejected;
      }

      // 非 HLS：先 HEAD（快失败），再必要时 Range GET 一轮。
      var resp = await _runValidationProbe(
        (cancelToken) => client.head(
          url,
          cancelToken: cancelToken,
          options: Options(
            headers: headers,
            receiveTimeout: probeTimeout,
            sendTimeout: probeTimeout,
          ),
        ),
        probeTimeout,
      );

      var code = resp.statusCode ?? 0;
      var contentType = resp.headers.value(HttpHeaders.contentTypeHeader);
      if (code != HttpStatus.ok && code != HttpStatus.partialContent) {
        if (!_headFallbackStatuses.contains(code)) {
          // 405/416/429/3xx 之类既非成功也非拒绝，不足以判死链。
          return MediaReachabilityVerdict.unknown;
        }
        // HEAD 被拒时只补一轮短 GET，不再拖第二长超时。
        final getTimeout = Duration(
          milliseconds: (probeTimeout.inMilliseconds * 0.85).round(),
        );
        resp = await _runValidationProbe(
          (cancelToken) => client.get(
            url,
            cancelToken: cancelToken,
            options: Options(
              headers: {...headers, 'Range': 'bytes=0-0'},
              responseType: ResponseType.bytes,
              receiveTimeout: getTimeout,
              sendTimeout: getTimeout,
            ),
          ),
          getTimeout,
        );
        code = resp.statusCode ?? 0;
        contentType = resp.headers.value(HttpHeaders.contentTypeHeader);
      }

      if (code == HttpStatus.ok || code == HttpStatus.partialContent) {
        if (contentType != null && _htmlLikeContentType.hasMatch(contentType)) {
          return MediaReachabilityVerdict.rejected;
        }
        return MediaReachabilityVerdict.reachable;
      }
      if (_rejectedStatuses.contains(code)) {
        // 404/410/5xx 说的是「现在没有」，401/403 说的是「这次没放行」。
        // 按需生成的临时媒体（`/temp/...`）首次访问常常如此，几秒后同一
        // 地址就能播：此类只保留，不判死。
        if (VideoUrlExtractor.isOnDemandMediaPath(url) &&
            _shouldKeepEphemeralOnReject(code, contentType)) {
          return MediaReachabilityVerdict.unknown;
        }
        return MediaReachabilityVerdict.rejected;
      }
      return MediaReachabilityVerdict.unknown;
    } on TimeoutException {
      // 探不到 ≠ 死链：冷 CDN、整集大文件的首包常常超出竞速预算。
      return MediaReachabilityVerdict.unknown;
    } on DioException {
      return MediaReachabilityVerdict.unknown;
    } catch (_) {
      return MediaReachabilityVerdict.unknown;
    }
  }

  static bool _playlistLooksAlive(int? statusCode, String? body) {
    final code = statusCode ?? 0;
    if (code != 200 && code != 206) return false;
    final text = body?.trimLeft() ?? '';
    if (text.isEmpty) return false;
    final head = text.length > 128 ? text.substring(0, 128) : text;
    final upper = head.toUpperCase();
    if (upper.contains('#EXT')) return true;
    if (upper.startsWith('<!DOCTYPE') ||
        upper.startsWith('<HTML') ||
        upper.startsWith('{') ||
        upper.contains('<HTML')) {
      return false;
    }
    return text.contains('#EXT');
  }

  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
  }) async {
    final url = await resolveDownloadUrl(
      episodeId,
      skipValidation: skipValidation,
      maxAttempts: maxAttempts,
      reachTimeout: reachTimeout,
    );
    final headers = Map<String, String>.from(mediaValidationHeaders)
      ..removeWhere((_, value) => value.isEmpty);
    if (url.isNotEmpty && VideoUrlExtractor.isSignedCdnUrl(url)) {
      headers.removeWhere((key, _) => key.toLowerCase() == 'referer');
    }
    return (url: url, httpHeaders: headers);
  }

  /// Starts any source-specific authorization refresh required while the
  /// resolved media is actively playing.
  Future<void> startPlaybackKeepAlive(String mediaUrl) =>
      SynchronousFuture(null);

  /// Allows adapters to prepare a stable player-facing representation of a
  /// resolved media URL, for example by materializing a remote HLS manifest.
  Future<({String url, Map<String, String> httpHeaders})> preparePlaybackMedia(
    ({String url, Map<String, String> httpHeaders}) media,
  ) => SynchronousFuture(media);

  /// Stops the active playback authorization refresh, if any.
  void stopPlaybackKeepAlive() {}

  @override
  String toString() => name;
}

/// GET request retry interceptor for transient network errors.
class RetryInterceptor extends Interceptor {
  final Dio dio;
  static const int _maxRetries = 2;

  RetryInterceptor(this.dio);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final opts = err.requestOptions;
    final retries = (opts.extra['__retry_count'] as int?) ?? 0;
    if (retries >= _maxRetries || !_shouldRetry(err)) {
      return handler.next(err);
    }
    opts.extra['__retry_count'] = retries + 1;
    try {
      handler.resolve(await dio.fetch(opts));
    } on DioException catch (e) {
      handler.next(e);
    } catch (_) {
      handler.next(err);
    }
  }

  bool _shouldRetry(DioException e) {
    if (e.requestOptions.method.toUpperCase() != 'GET') return false;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        return code == 429 || code == 502 || code == 503 || code == 504;
      default:
        return false;
    }
  }
}
