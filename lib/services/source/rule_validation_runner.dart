import 'dart:convert';

import 'package:baka/core/system_proxy.dart';
import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/site_probe_service.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

class RuleValidationRunner {
  RuleValidationRunner({Dio? mediaClient})
    : _mediaClient =
          mediaClient ??
          (Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              sendTimeout: const Duration(seconds: 8),
              followRedirects: true,
              maxRedirects: 4,
              validateStatus: (_) => true,
            ),
          )..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: SystemProxyService.createHttpClient,
          ));

  final Dio _mediaClient;

  void dispose() => _mediaClient.close(force: true);

  Future<RuleValidationReport> validate(
    CustomSourceConfig config, {
    required String keyword,
    String? preferredSeriesId,
    String? preferredEpisodeId,
  }) async {
    if (config.pipeline == null) {
      return const RuleValidationReport(
        success: false,
        stage: 'static',
        message: '缺少 anx-rule/2 pipeline',
      );
    }

    late final PipelineSourceAdapter adapter;
    try {
      final rule = config.toSourceRule();
      final staticValidation = RuleValidator.validate(rule);
      if (!staticValidation.isValid) {
        return RuleValidationReport(
          success: false,
          stage: 'static',
          message: staticValidation.errors.join('；'),
        );
      }
      adapter = PipelineSourceAdapter(rule);
    } catch (error) {
      return RuleValidationReport(
        success: false,
        stage: 'static',
        message: SiteProbeService.safeError(error),
      );
    }

    var seriesCount = 0;
    var lineCount = 0;
    var episodeCount = 0;
    try {
      final results = await adapter.search(keyword, enhanceWithBgm: false);
      seriesCount = results.length;
      if (results.isEmpty) {
        return const RuleValidationReport(
          success: false,
          stage: 'search',
          message: '搜索没有返回任何结果',
        );
      }

      final series = preferredSeriesId == null
          ? results.first
          : results.firstWhere(
              (item) => item.seriesId == preferredSeriesId,
              orElse: () => results.first,
            );
      final catalog = await adapter.getPlaybackCatalog(series.seriesId);
      lineCount = catalog.sourceNames.length;
      episodeCount = catalog.episodes.length;
      if (catalog.isEmpty) {
        return RuleValidationReport(
          success: false,
          stage: 'detail',
          message: '详情页没有提取到剧集或播放线路',
          seriesCount: seriesCount,
        );
      }

      String? episodeToken;
      if (preferredEpisodeId != null && preferredEpisodeId.isNotEmpty) {
        for (final ep in catalog.episodes) {
          if (ep.lines.contains(preferredEpisodeId)) {
            episodeToken = preferredEpisodeId;
            break;
          }
        }
      }
      if (episodeToken == null) {
        outer:
        for (final ep in catalog.episodes) {
          for (final line in ep.lines) {
            if (line.trim().isNotEmpty) {
              episodeToken = line;
              break outer;
            }
          }
        }
      }
      if (episodeToken == null) {
        return RuleValidationReport(
          success: false,
          stage: 'detail',
          message: '剧集列表中没有可解析的线路 token',
          seriesCount: seriesCount,
          lineCount: lineCount,
          episodeCount: episodeCount,
        );
      }

      final resolved = await adapter.resolvePlaybackMedia(
        episodeToken,
        maxAttempts: 1,
        reachTimeout: const Duration(seconds: 8),
      );
      if (resolved.url.isEmpty) {
        return RuleValidationReport(
          success: false,
          stage: 'play',
          message: '播放管线没有得到可达媒体地址',
          seriesCount: seriesCount,
          lineCount: lineCount,
          episodeCount: episodeCount,
        );
      }

      final prepared = await adapter.preparePlaybackMedia(resolved);
      final mediaKind = await _verifyMedia(prepared.url, prepared.httpHeaders);
      return RuleValidationReport(
        success: true,
        stage: 'media',
        message: '搜索、详情、播放解析和实际媒体读取均通过',
        seriesCount: seriesCount,
        lineCount: lineCount,
        episodeCount: episodeCount,
        mediaKind: mediaKind,
      );
    } catch (error) {
      return RuleValidationReport(
        success: false,
        stage: _stageFor(seriesCount, episodeCount),
        message: SiteProbeService.safeError(error),
        seriesCount: seriesCount,
        lineCount: lineCount,
        episodeCount: episodeCount,
      );
    } finally {
      adapter.dispose();
    }
  }

  Future<String> _verifyMedia(String url, Map<String, String> headers) async {
    final uri = Uri.parse(url);
    final looksHls = uri.path.toLowerCase().endsWith('.m3u8');
    if (!looksHls) {
      final response = await _mediaClient.get<List<int>>(
        url,
        options: Options(
          headers: {...headers, 'Range': 'bytes=0-1023'},
          responseType: ResponseType.bytes,
        ),
      );
      if (!_ok(response.statusCode) || (response.data?.isEmpty ?? true)) {
        throw StateError('媒体 Range 请求失败（HTTP ${response.statusCode ?? 0}）');
      }
      final contentType = response.headers.value('content-type')?.toLowerCase();
      final prefix = utf8
          .decode(response.data!, allowMalformed: true)
          .trimLeft();
      if (contentType?.contains('mpegurl') == true ||
          prefix.startsWith('#EXTM3U')) {
        return _verifyHls(uri, headers, prefix);
      }
      return 'file';
    }

    return _verifyHls(uri, headers, await _fetchText(uri, headers));
  }

  Future<String> _verifyHls(
    Uri initialUri,
    Map<String, String> headers,
    String initialManifest,
  ) async {
    var manifestUri = initialUri;
    var manifest = initialManifest;
    if (manifest.contains('#EXT-X-STREAM-INF')) {
      final variant = _firstMediaLine(manifest);
      if (variant == null) throw StateError('HLS 主清单没有可用变体');
      manifestUri = manifestUri.resolve(variant);
      manifest = await _fetchText(manifestUri, headers);
    }
    if (!manifest.trimLeft().startsWith('#EXTM3U')) {
      throw StateError('HLS 响应不是有效清单');
    }
    final segment = _firstMediaLine(manifest);
    if (segment == null) throw StateError('HLS 媒体清单没有实际分片');
    final response = await _mediaClient.get<List<int>>(
      manifestUri.resolve(segment).toString(),
      options: Options(
        headers: {...headers, 'Range': 'bytes=0-1023'},
        responseType: ResponseType.bytes,
      ),
    );
    if (!_ok(response.statusCode) || (response.data?.isEmpty ?? true)) {
      throw StateError('HLS 分片请求失败（HTTP ${response.statusCode ?? 0}）');
    }
    return 'hls-segment';
  }

  Future<String> _fetchText(Uri uri, Map<String, String> headers) async {
    final response = await _mediaClient.get<String>(
      uri.toString(),
      options: Options(headers: headers, responseType: ResponseType.plain),
    );
    if (!_ok(response.statusCode)) {
      throw StateError('HLS 清单请求失败（HTTP ${response.statusCode ?? 0}）');
    }
    return response.data ?? '';
  }

  static String? _firstMediaLine(String manifest) {
    final len = manifest.length;
    var lineStart = 0;
    while (lineStart < len) {
      var lineEnd = manifest.indexOf('\n', lineStart);
      if (lineEnd < 0) lineEnd = len;
      var start = lineStart;
      while (start < lineEnd && manifest.codeUnitAt(start) <= 32) {
        start++;
      }
      var end = lineEnd;
      while (end > start && manifest.codeUnitAt(end - 1) <= 32) {
        end--;
      }
      if (start < end && manifest.codeUnitAt(start) != 0x23) {
        return manifest.substring(start, end);
      }
      lineStart = lineEnd + 1;
    }
    return null;
  }

  static bool _ok(int? code) => code == 200 || code == 206;

  static String _stageFor(int seriesCount, int episodeCount) {
    if (seriesCount == 0) return 'search';
    if (episodeCount == 0) return 'detail';
    return 'play/media';
  }
}

