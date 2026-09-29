import 'dart:async';
import 'dart:io';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _manifest =
    '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n';
PipelineSourceAdapter _adapter(String base, {bool redirects = false}) =>
    PipelineSourceAdapter(
      SourceRule(
        id: 'lifecycle',
        name: 'Lifecycle',
        baseUrl: base,
        directConnection: true,
        play: [
          PipelineStep('template', {
            'value': '{episodeId:raw}',
            'materializeHls': true,
            'resolveMediaRedirects': redirects,
          }),
        ],
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
  });

  test('late A cannot replace B proxy or its media headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final aStarted = Completer<void>();
    final releaseA = Completer<void>();
    server.listen((request) async {
      if (request.uri.path == '/a.m3u8') {
        aStarted.complete();
        await releaseA.future;
      }
      try {
        request.response.write(
          request.uri.path.endsWith('.m3u8')
              ? _manifest
              : request.headers.value('X-Episode'),
        );
        await request.response.close();
      } catch (_) {}
    });
    final adapter = _adapter(base);
    final dio = Dio();
    addTearDown(() async {
      adapter.dispose();
      dio.close(force: true);
      await server.close(force: true);
    });
    final a = adapter.preparePlaybackMedia((
      url: '$base/a.m3u8',
      httpHeaders: const {'X-Episode': 'A'},
    ), filterHlsAds: false);
    final rejected = expectLater(a, throwsA(isA<RequestCancelledException>()));
    await aStarted.future;
    final b = await adapter.preparePlaybackMedia((
      url: '$base/b.m3u8',
      httpHeaders: const {'X-Episode': 'B'},
    ), filterHlsAds: false);
    releaseA.complete();
    await rejected;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final text = (await dio.get<String>(b.url)).data!;
    final segment = text
        .split('\n')
        .firstWhere((line) => line.startsWith('http'));
    expect((await dio.get<String>(segment)).data, 'B');
    adapter.dispose();
    await expectLater(dio.get<String>(b.url), throwsA(isA<DioException>()));
  });

  test(
    'disposing during preparation cancels HTTP and cannot install a server',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        started.complete();
        await release.future;
        try {
          request.response.write(_manifest);
          await request.response.close();
        } catch (_) {}
      });
      final adapter = _adapter('http://127.0.0.1:${server.port}');
      addTearDown(() => server.close(force: true));
      final work = adapter.preparePlaybackMedia((
        url: '${adapter.baseUrl}/slow.m3u8',
        httpHeaders: const {},
      ), filterHlsAds: false);
      final failure = expectLater(
        work,
        throwsA(isA<RequestCancelledException>()),
      );
      await started.future;
      adapter.dispose();
      release.complete();
      await failure;
      await expectLater(
        adapter.preparePlaybackMedia((
          url: '${adapter.baseUrl}/next.m3u8',
          httpHeaders: const {},
        )),
        throwsA(isA<RequestCancelledException>()),
      );
    },
  );

  test('same-origin redirect keeps credentials for player GET', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final methods = <String>[];
    server.listen((request) async {
      if (request.uri.path == '/entry') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/video.mp4');
      } else {
        methods.add(request.method);
        request.response.statusCode =
            request.headers.value('Cookie') == 'token=1' ? 200 : 403;
        if (request.method != 'HEAD') request.response.write('video');
      }
      await request.response.close();
    });
    final adapter = _adapter(base, redirects: true);
    final dio = Dio();
    addTearDown(() async {
      adapter.dispose();
      dio.close(force: true);
      await server.close(force: true);
    });
    final media = await adapter.preparePlaybackMedia((
      url: '$base/entry',
      httpHeaders: const {'Cookie': 'token=1'},
    ), filterHlsAds: false);
    expect(media.url, '$base/video.mp4');
    expect(
      (await dio.get<String>(
        media.url,
        options: Options(headers: media.httpHeaders),
      )).statusCode,
      200,
    );
    expect(methods, ['HEAD', 'GET']);
  });

  test(
    'explicit cancellation stops an in-flight fetch without a retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      var requests = 0;
      server.listen((request) {
        requests++;
        if (!started.isCompleted) started.complete();
      });
      final adapter = _adapter('http://127.0.0.1:${server.port}');
      final operation = SourceOperation();
      addTearDown(() async {
        operation.close();
        adapter.dispose();
        await server.close(force: true);
      });
      final work = adapter.fetch(
        '${adapter.baseUrl}/slow',
        operation: operation,
      );
      final failure = expectLater(
        work,
        throwsA(isA<RequestCancelledException>()),
      );
      await started.future;
      operation.cancel();
      await failure;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(requests, 1);
    },
  );
}
