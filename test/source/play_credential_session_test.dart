import 'dart:async';
import 'dart:io';

import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
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
    PipelineStep.fromJson({'op': 'setMediaHeaders', 'jsonPath': 'data.headers'}),
    PipelineStep.fromJson({'op': 'json', 'path': 'data.url'}),
  ],
);

/// 起一个只服务 `/play` 与 `/resolve` 的本地站点。
Future<({String base, Future<void> Function() close, int Function() playVisits})>
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

void main() {
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
      expect(
        site.overlapped,
        isFalse,
        reason: '第二条播放管线要等前一条解析完成后再访问播放页',
      );
      expect(site.playPageVisits, 2);
      expect(site.resolveCalls, 2);
    },
  );

  test('maxAttempts reruns the whole play pipeline after a rejected credential',
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
    final adapter = PipelineSourceAdapter(
      _dynamicRule(site.base),
    );
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
  });

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
    final adapter = PipelineSourceAdapter(
      _dynamicRule(site.base),
    );
    addTearDown(() async {
      adapter.dispose();
      await site.close();
    });

    final media = await adapter.resolvePlaybackMedia('ep1', maxAttempts: 2);
    expect(media.url, '${site.base}/live.m3u8');
    expect(resolveCalls, 2);
    expect(site.playVisits(), 2);
  });

  test('setMediaHeaders remove drops the rule Referer for third-party media',
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
  });
}
