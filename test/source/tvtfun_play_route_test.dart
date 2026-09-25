import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/store/bundled_rule_store.dart';
import 'package:test/test.dart';

/// tvtfun 的详情响应：两条线路，每线两集。站点给每个剧集带 `sort`
/// （从 0 起的集数下标），播放页用它当 `episode` 参数。
const Map<String, dynamic> _detailJson = <String, dynamic>{
  'data': <String, dynamic>{
    'name': '测试番',
    'slug': 'test-slug',
    'playSources': <dynamic>[
      <String, dynamic>{
        'id': 'srcA',
        'name': '线路A',
        'fromCode': 'source-1',
        'episodes': <dynamic>[
          <String, dynamic>{'id': 'epA0', 'name': '第1集', 'sort': 0},
          <String, dynamic>{'id': 'epA1', 'name': '第2集', 'sort': 1},
        ],
      },
      <String, dynamic>{
        'id': 'srcB',
        'name': '线路B',
        'fromCode': 'source-2',
        'episodes': <dynamic>[
          <String, dynamic>{'id': 'epB0', 'name': '第1集', 'sort': 0},
          <String, dynamic>{'id': 'epB1', 'name': '第2集', 'sort': 1},
        ],
      },
    ],
  },
};

class _Probe {
  _Probe(this.query, this.cookie, this.headers);

  final Map<String, String> query;
  final String? cookie;
  final Map<String, String> headers;
}

/// 复刻 tvtfun 的接口：播放页按 (source, episode) 下发凭证，
/// resolve 必须带上这张凭证才返回直链。
class _TvTFunSite {
  _TvTFunSite._(this._server, this.base);

  static Future<_TvTFunSite> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = _TvTFunSite._(
      server,
      'http://${server.address.address}:${server.port}',
    );
    server.listen(site._handle);
    return site;
  }

  final HttpServer _server;
  final String base;
  final List<_Probe> playPageVisits = <_Probe>[];
  final List<_Probe> resolveCalls = <_Probe>[];
  var _issued = 0;

  /// 置为 true 后播放页照常下发凭证，但 resolve 一律按站点的方式拒绝。
  var rejectResolve = false;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final uri = request.uri;
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.isEmpty ? '' : values.first;
    });
    final cookie = _cookieValue(request, 'tvt-pt');

    if (uri.path == '/api/videos/vid1') {
      request.response
        ..statusCode = HttpStatus.ok
        ..write(jsonEncode(_detailJson));
    } else if (uri.path.endsWith('/play')) {
      final credential = 'pt${++_issued}';
      playPageVisits.add(_Probe(uri.queryParameters, cookie, headers));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(
          HttpHeaders.setCookieHeader,
          'tvt-pt=$credential; Path=/',
        )
        ..write('<html><body>play</body></html>');
    } else if (uri.path == '/api/videos/resolve-play-url') {
      resolveCalls.add(_Probe(uri.queryParameters, cookie, headers));
      final episodeId = uri.queryParameters['episodeId'] ?? '';
      if (cookie == null || rejectResolve) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..write('{"error":"播放凭证无效，请刷新页面后重试"}');
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('{"data":{"url":"$base/media/$episodeId.m3u8"}}');
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    try {
      await request.response.close();
    } catch (_) {}
  }

  static String? _cookieValue(HttpRequest request, String name) {
    for (final cookie in request.cookies) {
      if (cookie.name == name) return cookie.value;
    }
    return null;
  }
}

/// 用真实的 tvtfun 规则跑测试，只把 baseUrl 换成本地站点。
SourceRule _tvtFunRule(String base) {
  final raw =
      jsonDecode(File(BundledRuleStore.builtinAssets['tvtfun']!).readAsStringSync())
          as Map<String, dynamic>;
  raw['baseUrl'] = base;
  raw['directConnection'] = true;
  return SourceRule.fromJson(raw);
}

void main() {
  test('episode ids keep their line index so the play page uses it', () async {
    final site = await _TvTFunSite.start();
    final adapter = PipelineSourceAdapter(_tvtFunRule(site.base));
    addTearDown(() async {
      adapter.dispose();
      await site.close();
    });

    final catalog = await adapter.getPlaybackCatalog('/api/videos/vid1');
    expect(catalog.sourceNames, ['线路A', '线路B']);
    expect(
      catalog.episodes.map((episode) => episode.lines).toList(),
      [
        ['epA0|test-slug|0|0', 'epB0|test-slug|1|0'],
        ['epA1|test-slug|0|1', 'epB1|test-slug|1|1'],
      ],
      reason: 'episodeId 要带上线路下标与集数下标，播放阶段才能还原播放页参数',
    );

    // 第二条线路的第二集：播放页必须请求 source=1&episode=1。
    final media = await adapter.resolvePlaybackMedia(
      'epB1|test-slug|1|1',
      skipValidation: true,
    );

    expect(media.url, '${site.base}/media/epB1.m3u8');
    expect(site.playPageVisits, hasLength(1));
    expect(site.playPageVisits.single.query, {
      'source': '1',
      'episode': '1',
    });
    expect(
      site.playPageVisits.single.headers['referer'],
      'https://www.tvtfun.net/video/test-slug',
    );
    expect(site.resolveCalls, hasLength(1));
    expect(site.resolveCalls.single.query['episodeId'], 'epB1');
    expect(
      site.resolveCalls.single.headers['referer'],
      'https://www.tvtfun.net/video/test-slug/play?source=1&episode=1',
      reason: '凭证与播放页绑定，resolve 的来源页必须与之一致',
    );
    expect(
      site.resolveCalls.single.headers['x-play-ctx'],
      isNotEmpty,
      reason: '站点用 X-Play-Ctx 判断播放器上下文',
    );
    expect(site.resolveCalls.single.cookie, isNotNull);
  });

  test('a rejected credential yields no media url', () async {
    final site = await _TvTFunSite.start();
    site.rejectResolve = true;
    final adapter = PipelineSourceAdapter(_tvtFunRule(site.base));
    addTearDown(() async {
      adapter.dispose();
      await site.close();
    });

    final media = await adapter.resolvePlaybackMedia(
      'epA0|test-slug|0|0',
      skipValidation: true,
      maxAttempts: 1,
    );

    // 站点拒绝凭证时不能把 {"error":...} 当直链交给播放器。
    expect(media.url, isEmpty);
    expect(site.resolveCalls.single.cookie, isNotNull);
  });
}
