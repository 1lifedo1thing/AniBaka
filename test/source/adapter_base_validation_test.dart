import 'dart:io';

import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
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

void main() {
  test('fast playback resolution does not wait for a media probe', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    var requests = 0;
    server.listen((request) async {
      requests++;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });

    final baseUrl = 'http://${server.address.address}:${server.port}';
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final validatedAdapter = _DirectUrlAdapter(
      '$baseUrl/validated-profile.mp4',
      'validated-profile-$suffix',
    );
    final validatedClock = Stopwatch()..start();
    await validatedAdapter.resolvePlaybackMedia('episode');
    validatedClock.stop();

    final fastAdapter = _DirectUrlAdapter(
      '$baseUrl/fast-profile.mp4',
      'fast-profile-$suffix',
    );
    final fastClock = Stopwatch()..start();
    final media = await fastAdapter.resolvePlaybackMedia(
      'episode',
      skipValidation: true,
    );
    fastClock.stop();

    // Keep a deterministic before/after sample in the test output so profile
    // runs can compare the old blocking path with the auto-match fast path.
    // ignore: avoid_print
    print(
      'AUTO_MATCH_DIRECT_PROFILE '
      'beforeMs=${validatedClock.elapsedMilliseconds} '
      'afterMs=${fastClock.elapsedMilliseconds}',
    );
    expect(media.url, '$baseUrl/fast-profile.mp4');
    expect(validatedClock.elapsedMilliseconds, greaterThanOrEqualTo(500));
    expect(fastClock.elapsedMilliseconds, lessThan(200));
    expect(requests, 1);
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
        ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
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

    server.listen((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
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

    // 竞速预算（150ms）内探不完 700ms 的响应：不能因此丢掉直链。
    expect(
      await adapter.resolveDownloadUrl(
        'episode',
        reachTimeout: const Duration(milliseconds: 150),
      ),
      url,
    );
    // 「未知」不入负缓存：预算给够后复探仍能确认可达。
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

  test('only on-demand path shapes relax the not-found verdict', () {    expect(
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
}
