import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/store/bundled_rule_store.dart';
import 'package:test/test.dart';

/// 模拟「播放页下发一次性凭证」的站点：tvtfun 的 `tvt-pt` 就是这种形态。
///
/// - `/play`：下发新凭证（cookie `pt`），上一张随即作废；
/// - `/resolve`：只认最新的一张凭证，用过即失效，其余情况返回 403。
class _CredentialSite {
  _CredentialSite._(this._server, this.base);

  static Future<_CredentialSite> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = _CredentialSite._(
      server,
      'http://${server.address.address}:${server.port}',
    );
    site._listen();
    return site;
  }

  final HttpServer _server;
  final String base;
  StreamSubscription<HttpRequest>? _subscription;

  var issued = 0;
  var resolveCalls = 0;
  var playPageVisits = 0;

  /// 上一次访问播放页时下发的凭证还没被解析消费——说明两条播放管线在并行。
  var overlapped = false;

  String? _latest;

  void _listen() {
    _subscription = _server.listen((request) async {
      switch (request.uri.path) {
        case '/play':
          playPageVisits++;
          if (_latest != null) overlapped = true;
          final credential = 'pt${++issued}';
          _latest = credential;
          await Future<void>.delayed(const Duration(milliseconds: 120));
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.set(HttpHeaders.setCookieHeader, 'pt=$credential; Path=/')
            ..write('<html><body>play</body></html>');
          break;
        case '/resolve':
          resolveCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 120));
          final credential = _cookieValue(request, 'pt');
          if (credential == null || credential != _latest) {
            request.response
              ..statusCode = HttpStatus.forbidden
              ..write('{"error":"播放凭证无效，请刷新页面后重试"}');
            break;
          }
          _latest = null;
          request.response
            ..statusCode = HttpStatus.ok
            ..write('{"data":{"url":"$base/media/$credential.m3u8"}}');
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      try {
        await request.response.close();
      } catch (_) {}
    });
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _server.close(force: true);
  }

  static String? _cookieValue(HttpRequest request, String name) {
    for (final cookie in request.cookies) {
      if (cookie.name == name) return cookie.value;
    }
    return null;
  }
}

SourceRule _credentialRule(String base) => SourceRule(
  id: 'credential-site',
  name: 'Credential site',
  baseUrl: base,
  directConnection: true,
  play: [
    PipelineStep.fromJson({
      'op': 'fetch',
      'url': '/play?source=0&episode=0',
      'cookieSession': true,
    }),
    PipelineStep.fromJson({
      'op': 'fetch',
      'url': '/resolve?episodeId={episodeId}',
    }),
    PipelineStep.fromJson({
      'op': 'setMediaHeaders',
      'jsonPath': 'data.headers',
    }),
    PipelineStep.fromJson({'op': 'json', 'path': 'data.url'}),
  ],
);

/// 播放管线带 `setMediaHeaders`，即应用里的「动态元数据」路径。
SourceRule _dynamicRule(String base) => SourceRule(
  id: 'dynamic-site',
  name: 'Dynamic site',
  baseUrl: base,
  directConnection: true,
  play: [
    PipelineStep.fromJson({'op': 'fetch', 'url': '/play'}),
    PipelineStep.fromJson({'op': 'fetch', 'url': '/resolve'}),
    PipelineStep.fromJson({
      'op': 'setMediaHeaders',
      'jsonPath': 'data.headers',
    }),
    PipelineStep.fromJson({'op': 'json', 'path': 'data.url'}),
  ],
);

/// 起一个只服务 `/play` 与 `/resolve` 的本地站点。
Future<
  ({String base, Future<void> Function() close, int Function() playVisits})
>
_serve(Future<void> Function(HttpRequest request) onResolve) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final base = 'http://${server.address.address}:${server.port}';
  var playVisits = 0;
  final subscription = server.listen((request) async {
    switch (request.uri.path) {
      case '/play':
        playVisits++;
        request.response
          ..statusCode = HttpStatus.ok
          ..write('<html><body>play</body></html>');
        break;
      case '/resolve':
        await onResolve(request);
        break;
      case '/dead.m3u8':
        request.response.statusCode = HttpStatus.forbidden;
      case '/live.m3u8':
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          )
          ..write('#EXTM3U\n#EXT-X-ENDLIST\n');
      default:
        request.response.statusCode = HttpStatus.notFound;
    }
    try {
      await request.response.close();
    } catch (_) {}
  });
  return (
    base: base,
    close: () async {
      await subscription.cancel();
      await server.close(force: true);
    },
    playVisits: () => playVisits,
  );
}

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
        ..headers.set(HttpHeaders.setCookieHeader, 'tvt-pt=$credential; Path=/')
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
      jsonDecode(
            File(BundledRuleStore.builtinAssets['tvtfun']!).readAsStringSync(),
          )
          as Map<String, dynamic>;
  raw['baseUrl'] = base;
  raw['directConnection'] = true;
  return SourceRule.fromJson(raw);
}

void main() {
  group('credential sessions', () {
    test(
      'cookieSession keeps concurrent play resolutions from swapping credentials',
      () async {
        final site = await _CredentialSite.start();
        final adapter = PipelineSourceAdapter(_credentialRule(site.base));
        addTearDown(() async {
          adapter.dispose();
          await site.close();
        });

        final results = await Future.wait([
          adapter.resolvePlaybackMedia('ep1', skipValidation: true),
          adapter.resolvePlaybackMedia('ep2', skipValidation: true),
        ]);

        expect(
          results.map((media) => media.url),
          everyElement(isNotEmpty),
          reason: '并发取流必须都拿到直链',
        );
        expect(site.overlapped, isFalse, reason: '第二条播放管线要等前一条解析完成后再访问播放页');
        expect(site.playPageVisits, 2);
        expect(site.resolveCalls, 2);
      },
    );

    test(
      'maxAttempts reruns the whole play pipeline after a rejected credential',
      () async {
        var resolveCalls = 0;
        final site = await _serve((request) async {
          resolveCalls++;
          // 第一次解析照着 tvtfun 的失败响应返回，第二次才给直链。
          request.response
            ..statusCode = resolveCalls == 1
                ? HttpStatus.forbidden
                : HttpStatus.ok
            ..write(
              resolveCalls == 1
                  ? '{"error":"播放凭证无效，请刷新页面后重试"}'
                  : '{"data":{"url":"${request.requestedUri.origin}/ok.m3u8"}}',
            );
        });
        final adapter = PipelineSourceAdapter(_dynamicRule(site.base));
        addTearDown(() async {
          adapter.dispose();
          await site.close();
        });

        final media = await adapter.resolvePlaybackMedia(
          'ep1',
          skipValidation: true,
          maxAttempts: 2,
        );
        expect(media.url, '${site.base}/ok.m3u8');
        expect(resolveCalls, 2);
        expect(site.playVisits(), 2, reason: '重试必须重新申请播放凭证');
      },
    );

    test('maxAttempts retries when the resolved media is rejected', () async {
      var resolveCalls = 0;
      final site = await _serve((request) async {
        resolveCalls++;
        final file = resolveCalls == 1 ? 'dead' : 'live';
        request.response
          ..statusCode = HttpStatus.ok
          ..write(
            '{"data":{"url":"${request.requestedUri.origin}/$file.m3u8"}}',
          );
      });
      final adapter = PipelineSourceAdapter(_dynamicRule(site.base));
      addTearDown(() async {
        adapter.dispose();
        await site.close();
      });

      final media = await adapter.resolvePlaybackMedia('ep1', maxAttempts: 2);
      expect(media.url, '${site.base}/live.m3u8');
      expect(resolveCalls, 2);
      expect(site.playVisits(), 2);
    });

    test(
      'setMediaHeaders remove drops the rule Referer for third-party media',
      () async {
        SourceRule rule({required bool dropReferer}) => SourceRule(
          id: 'media-headers-site',
          name: 'Media headers site',
          baseUrl: 'https://www.example.com',
          headers: const {
            'Referer': 'https://www.example.com/',
            'User-Agent': 'rule-user-agent',
          },
          play: [
            PipelineStep.fromJson({
              'op': 'template',
              'value': 'https://cdn.example.net/show/ep1.m3u8',
            }),
            PipelineStep.fromJson({
              'op': 'setMediaHeaders',
              if (dropReferer) 'remove': ['Referer'],
            }),
          ],
        );

        final kept = PipelineSourceAdapter(rule(dropReferer: false));
        addTearDown(kept.dispose);
        final keptMedia = await kept.resolvePlaybackMedia(
          'ep1',
          skipValidation: true,
        );
        expect(keptMedia.httpHeaders['Referer'], 'https://www.example.com/');

        // 第三方 CDN 不接受站点 Referer：去掉后只留通用头，播放器不带站点来源。
        final dropped = PipelineSourceAdapter(rule(dropReferer: true));
        addTearDown(dropped.dispose);
        final droppedMedia = await dropped.resolvePlaybackMedia(
          'ep1',
          skipValidation: true,
        );
        expect(droppedMedia.url, 'https://cdn.example.net/show/ep1.m3u8');
        expect(droppedMedia.httpHeaders.containsKey('Referer'), isFalse);
        expect(droppedMedia.httpHeaders['User-Agent'], isNotEmpty);
      },
    );
  });

  group('TvTFun routes', () {
    test(
      'episode ids keep their line index so the play page uses it',
      () async {
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
      },
    );

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
  });

  group('keep alive', () {
    test(
      'pipeline playback keep-alive repeats templates and stops cleanly',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <({Uri uri, String referer})>[];
        final pulses = StreamController<void>.broadcast();
        addTearDown(pulses.close);
        final secondPulse = pulses.stream.take(2).drain<void>();
        final subscription = server.listen((request) {
          pulses.add(null);
          requests.add((
            uri: request.uri,
            referer: request.headers.value(HttpHeaders.refererHeader) ?? '',
          ));
          request.response
            ..statusCode = HttpStatus.ok
            ..write('ok')
            ..close();
        });

        final pulseUrl =
            'http://${server.address.address}:${server.port}/pulse'
            '?st={st}&token={token}';
        final rule = SourceRule(
          id: 'keep_alive_test',
          name: 'keep alive test',
          baseUrl: 'https://example.com',
          directConnection: true,
          play: [
            PipelineStep.fromJson({
              'op': 'fetch',
              'url': pulseUrl,
              'playbackKeepAlive': true,
              'intervalSeconds': 1,
              'expectedBody': 'ok',
              'variables': {
                'playerUrl':
                    'https://video.example/player/?url={mediaUrl}&st={st}',
              },
              'headers': {'Referer': '{playerUrl:raw}'},
            }),
          ],
        );
        final adapter = PipelineSourceAdapter(rule);
        const mediaUrl =
            'https://video.example/show/episode.m3u8'
            '?st=session-value&e=123&token=token-value';

        try {
          await adapter.startPlaybackKeepAlive(mediaUrl);
          await secondPulse.timeout(const Duration(seconds: 5));

          expect(requests.length, greaterThanOrEqualTo(2));
          expect(requests.first.uri.queryParameters['st'], 'session-value');
          expect(requests.first.uri.queryParameters['token'], 'token-value');
          expect(
            requests.first.referer,
            'https://video.example/player/'
            '?url=${Uri.encodeComponent(mediaUrl)}&st=session-value',
          );

          adapter.stopPlaybackKeepAlive();
          await expectLater(
            pulses.stream.timeout(
              const Duration(milliseconds: 1100),
              onTimeout: (sink) => sink.close(),
            ),
            emitsDone,
          );
        } finally {
          adapter.stopPlaybackKeepAlive();
          await subscription.cancel();
          await server.close(force: true);
        }
      },
    );
  });
}
