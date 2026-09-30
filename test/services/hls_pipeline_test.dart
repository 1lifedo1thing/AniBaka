import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:baka/core/app_storage.dart';
import 'package:baka/models/download_task.dart';
import 'package:baka/services/download/download_manager.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import '../support/ts_prefix_fixtures.dart';

/// 主清单：单码率变体，和实测的 dytt-tvs 主清单同构。
const _masterPlaylist = '''
#EXTM3U
#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=800000,RESOLUTION=1920x816
3000k/hls/mixed.m3u8
''';

/// 媒体清单：5 个正片组（每组 3 片 x 4s = 12s，共 60s）+ 1 个广告组
/// （2 片 x 4s = 8s）。广告占 8/68 ≈ 11.8%，低于 15% 的占比闸门。
const _mediaPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:8
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-DISCONTINUITY
#EXTINF:4.000,
content_0.ts
#EXTINF:4.000,
content_1.ts
#EXTINF:4.000,
content_2.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.000,
content_3.ts
#EXTINF:4.000,
content_4.ts
#EXTINF:4.000,
content_5.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.000,
ad_0.ts
#EXTINF:4.000,
ad_1.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.000,
content_6.ts
#EXTINF:4.000,
content_7.ts
#EXTINF:4.000,
content_8.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.000,
content_9.ts
#EXTINF:4.000,
content_10.ts
#EXTINF:4.000,
content_11.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.000,
content_12.ts
#EXTINF:4.000,
content_13.ts
#EXTINF:4.000,
content_14.ts
#EXT-X-ENDLIST
''';

/// 假 CDN：主清单、媒体清单与分片都在本机，分片按正片/广告返回真实前缀。
class _FakeCdn {
  _FakeCdn(this.server, {this.encrypted = false});

  final HttpServer server;
  final bool encrypted;
  final List<String> paths = [];
  final Map<String, String?> referers = {};
  final Map<String, String?> ranges = {};

  String get origin => 'http://127.0.0.1:${server.port}';

  static Future<_FakeCdn> start({bool encrypted = false}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final cdn = _FakeCdn(server, encrypted: encrypted);
    server.listen(cdn._handle);
    return cdn;
  }

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    paths.add(path);
    referers[path] = request.headers.value(HttpHeaders.refererHeader);
    ranges[path] = request.headers.value(HttpHeaders.rangeHeader);
    final response = request.response;

    switch (path) {
      case '/index.m3u8':
        return _writePlaylist(response, _masterPlaylist, encrypted: encrypted);
      case '/3000k/hls/mixed.m3u8':
        return _writePlaylist(response, _mediaPlaylist, encrypted: encrypted);
    }

    final segment = switch (path) {
      _ when path.endsWith('/ad_0.ts') || path.endsWith('/ad_1.ts') =>
        adPrefixBytes,
      _ when path.contains('content_') => contentPrefixBytes,
      _ => null,
    };
    if (segment == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    return _writeSegment(response, segment, ranges[path]);
  }

  static Future<void> _writePlaylist(
    HttpResponse response,
    String body, {
    bool encrypted = false,
  }) async {
    response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
      charset: 'utf-8',
    );
    if (encrypted) {
      response.add([
        101,
        110,
        99,
        ...utf8.encode(body).map((byte) => byte ^ 7),
      ]);
    } else {
      response.write(body);
    }
    await response.close();
  }

  static Future<void> _writeSegment(
    HttpResponse response,
    List<int> bytes,
    String? range,
  ) async {
    final match = range == null
        ? null
        : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    response.headers.contentType = ContentType('video', 'mp2t');
    if (match == null) {
      response.statusCode = HttpStatus.ok;
      response.contentLength = bytes.length;
      response.add(bytes);
      await response.close();
      return;
    }
    final start = int.parse(match.group(1)!);
    final requestedEnd = match.group(2)!.isEmpty
        ? bytes.length - 1
        : int.parse(match.group(2)!);
    final end = requestedEnd >= bytes.length ? bytes.length - 1 : requestedEnd;
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${bytes.length}',
    );
    response.contentLength = end - start + 1;
    response.add(bytes.sublist(start, end + 1));
    await response.close();
  }
}

/// 代理清单里每个分片地址（`/media/<id>`）。
List<String> _proxySegments(String manifest) => manifest
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.startsWith('http://127.0.0.1:'))
    .toList();

int _countLines(String text, String value) =>
    text.split('\n').where((line) => line.trim() == value).length;

Future<({int status, List<int> bytes})> _get(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    return (status: response.statusCode, bytes: bytes);
  } finally {
    client.close(force: true);
  }
}

String _decode(List<int> bytes) => utf8.decode(bytes);

void main() {
  group('offline download lifecycle', () {
    late Directory directory;
    late HttpServer server;
    late DownloadService service;
    late Map<int, int> requests;
    late Completer<void> blocked;
    Completer<void>? release;
    var active = 0, maximum = 0;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('hls-download-');
      Hive.init(directory.path);
      await Hive.openBox<List>(AppStorage.downloadTasksBoxName);
      service = DownloadService();
      await service.init();
      requests = {};
      blocked = Completer<void>();
      release = null;
      active = maximum = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/index.m3u8') {
          response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
            '${List.generate(12, (i) => '#EXTINF:4,\n$i.ts\n').join()}'
            '#EXT-X-ENDLIST\n',
          );
          await response.close();
          return;
        }
        final index = int.parse(request.uri.path.substring(1).split('.').first);
        requests.update(index, (count) => count + 1, ifAbsent: () => 1);
        active++;
        if (active > maximum) maximum = active;
        if (index == 4 && !blocked.isCompleted) blocked.complete();
        try {
          if (index > 0 && release != null) await release!.future;
          response.contentLength = 8 * 4096;
          for (var chunk = 0; chunk < 8; chunk++) {
            response.add(List.filled(4096, index));
            await response.flush();
            // Simulate a streaming origin; this delay belongs only to the fixture.
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          await response.close();
        } catch (_) {
          // Pausing and deleting deliberately close these responses early.
        } finally {
          active--;
        }
      });
    });
    tearDown(() async {
      if (release != null && !release!.isCompleted) release!.complete();
      await service.dispose();
      await server.close(force: true);
      await Hive.close();
      await directory.delete(recursive: true);
    });
    DownloadTask task() => DownloadTask(
      id: 'fixture',
      url: 'http://127.0.0.1:${server.port}/index.m3u8',
      filename: 'fixture.m3u8',
      title: 'Fixture',
      filePath: '${directory.path}/fixture.hls/index.m3u8',
    );

    test(
      'concurrent downloads preserve manifest order and complete every segment',
      () async {
        final download = task();
        final completed = Completer<void>();
        service.onCompleted = (_) => completed.complete();
        service.addTasks([download]);
        await completed.future.timeout(const Duration(seconds: 5));
        expect(maximum, inInclusiveRange(2, 4));
        expect(requests.values, everyElement(1));
        expect(requests, hasLength(12));
        expect(download.progress, 1);
        expect(await File(download.filePath!).readAsBytes(), [
          for (var i = 0; i < 12; i++) ...List.filled(8 * 4096, i),
        ]);
      },
    );

    test(
      'pause drains requests, restart reuses completed segments, delete drains before removal',
      () async {
        release = Completer<void>();
        final download = task();
        service.addTasks([download]);
        await blocked.future.timeout(const Duration(seconds: 5));
        service.pause(download);
        await service.dispose().timeout(const Duration(seconds: 3));
        expect(download.status, DownloadStatus.paused);
        release!.complete();
        service = DownloadService();
        await service.init();
        final restored = service.tasks.single;
        final completed = Completer<void>();
        service.onCompleted = (_) => completed.complete();
        service.resume(restored);
        await completed.future.timeout(const Duration(seconds: 5));
        expect(requests[0], 1, reason: 'Completed segment survives restart');
        expect(await File(restored.filePath!).length(), 12 * 8 * 4096);

        // A different active download is deleted while responses are blocked.
        release = Completer<void>();
        blocked = Completer<void>();
        final deleting = DownloadTask(
          id: 'delete',
          url: download.url,
          filename: 'delete.m3u8',
          title: 'Delete',
          filePath: '${directory.path}/delete.hls/index.m3u8',
        );
        service.addTasks([deleting]);
        await blocked.future.timeout(const Duration(seconds: 5));
        service.delete(deleting);
        await service.dispose().timeout(const Duration(seconds: 3));
        expect(
          await Directory('${directory.path}/delete.hls').exists(),
          isFalse,
        );
      },
    );
  });

  test('开启 filterHlsAds：主清单落到变体，丢掉整组广告后再物化', () async {
    final cdn = await _FakeCdn.start();
    final adapter = PipelineSourceAdapter(
      SourceRule(
        id: 'hls-ad-test',
        name: 'HLS ad test',
        baseUrl: cdn.origin,
        play: const [
          PipelineStep('noop', {'filterHlsAds': true}),
        ],
      ),
    );

    try {
      String? timelineKey;
      final prepared = await adapter.preparePlaybackMedia((
        url: '${cdn.origin}/index.m3u8',
        httpHeaders: {HttpHeaders.refererHeader: 'https://source/'},
      ), onTimelinePrepared: (key) => timelineKey = key);
      expect(timelineKey, matches(RegExp(r'^hls:[a-f0-9]{64}$')));

      // 主清单 → 变体 → 媒体清单 → 本地代理清单。
      expect(prepared.url, startsWith('http://127.0.0.1:'));
      expect(prepared.url, endsWith('/manifest.m3u8'));
      expect(prepared.httpHeaders, isEmpty);
      expect(cdn.paths, contains('/index.m3u8'));
      expect(cdn.paths, contains('/3000k/hls/mixed.m3u8'));

      // 探测：每组首片一次 16 KB Range 请求，带上原 Referer；广告组再逐片复测。
      // 分片地址按媒体清单所在的 /3000k/hls/ 解析。
      expect(cdn.referers['/3000k/hls/content_0.ts'], 'https://source/');
      expect(cdn.ranges['/3000k/hls/content_0.ts'], 'bytes=0-16383');
      expect(cdn.ranges['/3000k/hls/ad_0.ts'], 'bytes=0-16383');
      expect(cdn.ranges['/3000k/hls/ad_1.ts'], 'bytes=0-16383');
      // 与主体指纹一致的组不再深入，只探首片。
      expect(cdn.paths, isNot(contains('/3000k/hls/content_1.ts')));

      final manifest = _decode((await _get(prepared.url)).bytes);
      final segments = _proxySegments(manifest);
      // 17 片里丢掉广告组的 2 片，广告组自带的 discontinuity 一并删掉。
      expect(segments, hasLength(15));
      expect(_countLines(manifest, '#EXT-X-DISCONTINUITY'), 5);
      expect(manifest, contains('#EXT-X-MEDIA-SEQUENCE:0'));
      expect(manifest, contains('#EXT-X-ENDLIST'));

      // 15 个代理分片取到的都是正片前缀，广告分片一个都没进代理表。
      for (final segment in segments) {
        final fetched = await _get(segment);
        expect(fetched.status, HttpStatus.ok);
        expect(fetched.bytes, equals(contentPrefixBytes));
      }
    } finally {
      adapter.dispose();
      await cdn.close();
    }
  });

  test(
    'declared binary decoder materializes master and variant without ad filtering',
    () async {
      final cdn = await _FakeCdn.start(encrypted: true);
      final adapter = PipelineSourceAdapter(
        SourceRule(
          id: 'hls-decode-test',
          name: 'HLS decode test',
          baseUrl: cdn.origin,
          play: const [
            PipelineStep('noop', {
              'hlsManifestDecode': {
                'scheme': 'xor',
                'prefix': 'enc',
                'key': [0],
                'period': 1,
                'fallbackIndex': 0,
                'xor': 7,
                'skipBytes': 3,
              },
            }),
          ],
        ),
      );
      try {
        final prepared = await adapter.preparePlaybackMedia((
          url: '${cdn.origin}/index.m3u8',
          httpHeaders: const {'Referer': 'https://example.org/'},
        ));
        expect(prepared.url, isNot('${cdn.origin}/index.m3u8'));
        expect(cdn.paths, contains('/3000k/hls/mixed.m3u8'));
        final manifest = _decode((await _get(prepared.url)).bytes);
        expect(manifest, startsWith('#EXTM3U'));
        expect(manifest, contains('#EXT-X-ENDLIST'));
        final segments = _proxySegments(manifest);
        expect(segments, hasLength(17));
        expect((await _get(segments.first)).bytes, contentPrefixBytes);
        expect(cdn.referers['/3000k/hls/content_0.ts'], 'https://example.org/');
      } finally {
        adapter.dispose();
        await cdn.close();
      }
    },
  );

  test('未开启 filterHlsAds 时主清单仍回落到原始地址', () async {
    final cdn = await _FakeCdn.start();
    final adapter = PipelineSourceAdapter(
      SourceRule(
        id: 'hls-materialize-test',
        name: 'HLS materialize test',
        baseUrl: cdn.origin,
        play: const [
          PipelineStep('noop', {'materializeHls': true}),
        ],
      ),
    );

    try {
      final prepared = await adapter.preparePlaybackMedia((
        url: '${cdn.origin}/index.m3u8',
        httpHeaders: const {},
      ));

      expect(prepared.url, '${cdn.origin}/index.m3u8');
      expect(cdn.paths, isNot(contains('/3000k/hls/mixed.m3u8')));
    } finally {
      adapter.dispose();
      await cdn.close();
    }
  });

  test('规则未开启但手动传入 filterHlsAds: true 时触发去广告与物化', () async {
    final cdn = await _FakeCdn.start();
    final adapter = PipelineSourceAdapter(
      SourceRule(
        id: 'hls-manual-filter-test',
        name: 'HLS manual filter test',
        baseUrl: cdn.origin,
        play: const [PipelineStep('noop', {})],
      ),
    );

    try {
      final prepared = await adapter.preparePlaybackMedia((
        url: '${cdn.origin}/index.m3u8',
        httpHeaders: const {},
      ), filterHlsAds: true);

      expect(prepared.url, startsWith('http://127.0.0.1:'));
      expect(cdn.paths, contains('/3000k/hls/mixed.m3u8'));
    } finally {
      adapter.dispose();
      await cdn.close();
    }
  });
}
