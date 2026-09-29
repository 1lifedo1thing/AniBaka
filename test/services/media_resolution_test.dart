import 'dart:async';
import 'dart:io';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

class _DirectUrlAdapter extends AdapterBase {
  _DirectUrlAdapter(this.mediaUrl, String name) : super(name);

  final String mediaUrl;

  @override
  String get baseUrl => mediaUrl;

  @override
  Future<String> getDownloadUrl(String episodeId) async => mediaUrl;

  @override
  Future<PlaybackCatalog> getPlaybackCatalog(String seriesId) async =>
      PlaybackCatalog.empty;

  @override
  Future<List<Series>> search(
    String query, {
    bool enhanceWithBgm = true,
  }) async => const [];
}

class _CachedUrlAdapter extends PipelineSourceAdapter {
  _CachedUrlAdapter(String id, this.url)
    : super(
        SourceRule(
          id: id,
          name: 'Same name',
          baseUrl: 'https://fixture.invalid',
        ),
      );
  String url;
  int calls = 0;
  @override
  Future<String> getDownloadUrl(String id) async {
    calls++;
    return url;
  }
}

void main() {
  test('episode invalidation forces one fresh parse, then caches it', () async {
    final adapter = _CachedUrlAdapter(
      'refresh',
      'https://fixture.invalid/old.mp4',
    );
    addTearDown(adapter.dispose);
    await adapter.resolveDownloadUrl('1', skipValidation: true);
    adapter.url = 'https://fixture.invalid/new.mp4';
    adapter.invalidateDownloadUrl('1');
    expect(
      await adapter.resolveDownloadUrl('1', skipValidation: true),
      adapter.url,
    );
    expect(
      await adapter.resolveDownloadUrl('1', skipValidation: true),
      adapter.url,
    );
    expect(adapter.calls, 2);
  });

  group('validation', () {
    test('fast playback resolution skips media probing', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        fail('skipValidation unexpectedly sent a media probe');
      });
      final url = 'http://${server.address.address}:${server.port}/video.mp4';
      final adapter = _DirectUrlAdapter(url, 'fast-profile');
      addTearDown(adapter.dispose);
      final media = await adapter.resolvePlaybackMedia(
        'episode',
        skipValidation: true,
      );
      expect(media.url, url);
    });

    test('range GET confirms a playable URL when HEAD is rejected', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      var headRequests = 0;
      var getRequests = 0;
      server.listen((request) async {
        if (request.method == 'HEAD') {
          headRequests++;
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          getRequests++;
          expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=0-0');
          request.response
            ..statusCode = HttpStatus.partialContent
            ..headers.contentType = ContentType('video', 'mp4')
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1')
            ..add([0]);
        }
        await request.response.close();
      });

      final url = 'http://${server.address.address}:${server.port}/孤独摇滚/01.mp4';
      final adapter = _DirectUrlAdapter(
        url,
        'head-fallback-${DateTime.now().microsecondsSinceEpoch}',
      );

      expect(await adapter.resolveDownloadUrl('episode'), url);
      expect(headRequests, 1);
      expect(getRequests, 1);
    });

    test('range GET rejection still blocks an invalid URL', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final url = 'http://${server.address.address}:${server.port}/missing.mp4';
      final adapter = _DirectUrlAdapter(
        url,
        'blocked-${DateTime.now().microsecondsSinceEpoch}',
      );

      expect(await adapter.resolveDownloadUrl('episode'), isEmpty);
    });

    test('query-marked HLS endpoint is validated as a playlist', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      var requests = 0;
      server.listen((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=0-2047');
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          )
          ..write('#EXTM3U\n#EXT-X-VERSION:4\n');
        await request.response.close();
      });

      final url =
          'http://${server.address.address}:${server.port}/issue-hls-playback'
          '?mode=playlist&resource=episode-1';
      final adapter = _DirectUrlAdapter(
        url,
        'query-hls-${DateTime.now().microsecondsSinceEpoch}',
      );

      expect(await adapter.resolveDownloadUrl('episode'), url);
      expect(requests, 1);
    });

    test('a slow media probe keeps the direct url', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.listen((request) async {
        await release.future;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('video', 'mp4');
        try {
          await request.response.close();
        } catch (_) {}
      });

      final url =
          'http://${server.address.address}:${server.port}/temp/2607/与你01.mp4';
      final adapter = _DirectUrlAdapter(
        url,
        'slow-direct-${DateTime.now().microsecondsSinceEpoch}',
      );

      // Hold the response until the short probe budget expires.
      expect(
        await adapter.resolveDownloadUrl(
          'episode',
          reachTimeout: const Duration(milliseconds: 150),
        ),
        url,
      );
      release.complete();
      // Unknown results must not poison later successful probes.
      expect(
        await adapter.resolveDownloadUrl(
          'episode',
          forceRefresh: true,
          reachTimeout: const Duration(seconds: 5),
        ),
        url,
      );
    });

    test('extension-less stream urls are probed instead of rejected', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('video', 'mp4');
        await request.response.close();
      });

      // 网盘取流地址没有视频扩展名，形态上判不出是媒体，只能靠探测。
      final url =
          'http://${server.address.address}:${server.port}/pan/download'
          '?fid=${DateTime.now().microsecondsSinceEpoch}';
      final adapter = _DirectUrlAdapter(
        url,
        'bare-stream-${DateTime.now().microsecondsSinceEpoch}',
      );

      expect(await adapter.resolveDownloadUrl('episode'), url);
    });

    test('a 200 html shell is still rejected', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write('<!DOCTYPE html><html><body>解析失败</body></html>');
        await request.response.close();
      });

      final url =
          'http://${server.address.address}:${server.port}/media/parse'
          '?id=${DateTime.now().microsecondsSinceEpoch}';
      final adapter = _DirectUrlAdapter(
        url,
        'html-shell-${DateTime.now().microsecondsSinceEpoch}',
      );

      expect(await adapter.resolveDownloadUrl('episode'), isEmpty);
    });

    test('a not-yet-generated temp file is kept instead of convicted', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      var requests = 0;
      server.listen((request) async {
        requests++;
        // 前两次（HEAD + Range GET）文件还没落盘，之后按需生成成功。
        if (requests <= 2) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('video', 'mp4');
        }
        await request.response.close();
      });

      final url =
          'http://${server.address.address}:${server.port}/temp/2607/与你01.mp4';
      final adapter = _DirectUrlAdapter(
        url,
        'on-demand-${DateTime.now().microsecondsSinceEpoch}',
      );

      // 临时媒体首包 404 只说明「还没生成」：保留直链交给播放器验证。
      expect(await adapter.resolveDownloadUrl('episode'), url);
      // 且不写负缓存：文件出现后复探立刻确认为可达。
      expect(
        await adapter.resolveDownloadUrl('episode', forceRefresh: true),
        url,
      );
      expect(requests, greaterThanOrEqualTo(3));
    });

    test('an auth-rejected temp file is kept for the player', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      var requests = 0;
      server.listen((request) async {
        requests++;
        // 裸探测（HEAD / bytes=0-0）被 CDN 按 token 拒掉，播放器仍可用完整请求取流。
        request.response
          ..statusCode = HttpStatus.forbidden
          ..headers.contentType = ContentType('video', 'mp4');
        await request.response.close();
      });

      final url =
          'http://${server.address.address}:${server.port}/temp/2607/与你01.mp4';
      final adapter = _DirectUrlAdapter(
        url,
        'on-demand-auth-${DateTime.now().microsecondsSinceEpoch}',
      );

      expect(await adapter.resolveDownloadUrl('episode'), url);
      expect(requests, greaterThanOrEqualTo(2));
    });

    test('a forbidden non-temp file is still discarded', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });

      final url =
          'http://${server.address.address}:${server.port}/vod/2607/01.mp4';
      final adapter = _DirectUrlAdapter(
        url,
        'forbidden-vod-${DateTime.now().microsecondsSinceEpoch}',
      );

      expect(await adapter.resolveDownloadUrl('episode'), isEmpty);
    });

    test('a forbidden html block page is still discarded', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..headers.contentType = ContentType.html
          ..write('<!DOCTYPE html><html><body>Access denied</body></html>');
        await request.response.close();
      });

      final url =
          'http://${server.address.address}:${server.port}/temp/2607/01.mp4';
      final adapter = _DirectUrlAdapter(
        url,
        'forbidden-html-${DateTime.now().microsecondsSinceEpoch}',
      );

      expect(await adapter.resolveDownloadUrl('episode'), isEmpty);
    });

    test('only on-demand path shapes relax the not-found verdict', () {
      expect(
        VideoUrlExtractor.isOnDemandMediaPath(
          'https://play.xfvod.pro:8088/temp/2607/与你01.mp4',
        ),
        isTrue,
      );
      expect(
        VideoUrlExtractor.isOnDemandMediaPath(
          'https://cdn.example.com/cache/2607/01.m3u8',
        ),
        isTrue,
      );
      expect(
        VideoUrlExtractor.isOnDemandMediaPath(
          'https://cdn.example.com/media/parse?id=1',
        ),
        isFalse,
      );
      expect(
        VideoUrlExtractor.isOnDemandMediaPath(
          'https://cdn.example.com/vod/01.mp4',
        ),
        isFalse,
      );
    });
  });

  group('redirects', () {
    test('resolves redirects without proxying the media body', () async {
      final entry = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final resolver = RemoteMediaRedirectResolver();
      var finalRequests = 0;
      final entrySubscription = entry.listen((request) async {
        expect(request.method, 'HEAD');
        expect(
          request.headers.value(HttpHeaders.refererHeader),
          'https://source/',
        );
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${target.port}/video.mp4',
          );
        await request.response.close();
      });
      final targetSubscription = target.listen((request) async {
        expect(request.method, 'HEAD');
        expect(request.headers.value(HttpHeaders.refererHeader), isNull);
        finalRequests++;
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = 1024;
        await request.response.close();
      });

      try {
        final finalUrl = await resolver.resolve(
          'http://127.0.0.1:${entry.port}/redirect',
          headers: {HttpHeaders.refererHeader: 'https://source/'},
        );

        expect(finalUrl, 'http://127.0.0.1:${target.port}/video.mp4');
        expect(finalRequests, 1);
      } finally {
        resolver.close();
        await entrySubscription.cancel();
        await targetSubscription.cancel();
        await entry.close(force: true);
        await target.close(force: true);
      }
    });

    test('leaves non-http media untouched', () async {
      final resolver = RemoteMediaRedirectResolver();
      addTearDown(resolver.close);

      expect(
        await resolver.resolve('magnet:?xt=urn:btih:test'),
        startsWith('magnet:'),
      );
    });

    test('pipeline redirect flag prepares the final player URL', () async {
      final entry = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final entrySubscription = entry.listen((request) async {
        expect(
          request.headers.value(HttpHeaders.refererHeader),
          'https://source/',
        );
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${target.port}/video.mp4',
          );
        await request.response.close();
      });
      final targetSubscription = target.listen((request) async {
        expect(request.headers.value(HttpHeaders.refererHeader), isNull);
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = 1024;
        await request.response.close();
      });
      final adapter = PipelineSourceAdapter(
        SourceRule(
          id: 'redirect-test',
          name: 'Redirect test',
          baseUrl: 'http://127.0.0.1:${entry.port}',
          play: const [
            PipelineStep('noop', {'resolveMediaRedirects': true}),
          ],
        ),
      );

      try {
        final prepared = await adapter.preparePlaybackMedia((
          url: 'http://127.0.0.1:${entry.port}/redirect',
          httpHeaders: {HttpHeaders.refererHeader: 'https://source/'},
        ));

        expect(prepared.url, 'http://127.0.0.1:${target.port}/video.mp4');
        expect(
          prepared.httpHeaders,
          isNot(contains(HttpHeaders.refererHeader)),
        );
      } finally {
        adapter.dispose();
        await entrySubscription.cancel();
        await targetSubscription.cancel();
        await entry.close(force: true);
        await target.close(force: true);
      }
    });
  });
}
