import 'dart:async';
import 'dart:io';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final end in ['done', 'cancel', 'unread cancel', 'error']) {
    test('stream slot held until $end, then released once', () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previous);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        try {
          request.response.contentLength = 2;
          request.response.write('a');
          await request.response.flush();
          if (request.uri.path == '/first') await release.future;
          if (end != 'error' || request.uri.path != '/first') {
            request.response.write('b');
          }
          await request.response.close();
        } catch (_) {}
      });
      final scheduler = RequestScheduler(maxConcurrent: 1, maxPerHost: 1);
      final dio = Dio()
        ..interceptors.add(SchedulerInterceptor(scheduler: scheduler));
      addTearDown(() async {
        dio.close(force: true);
        await server.close(force: true);
      });
      final base = 'http://127.0.0.1:${server.port}';
      final cancel = CancelToken();
      final first = await dio.get<ResponseBody>(
        '$base/first',
        cancelToken: cancel,
        options: Options(responseType: ResponseType.stream),
      );
      StreamSubscription<List<int>>? subscription;
      if (end == 'cancel') subscription = first.data!.stream.listen((_) {});
      final second = dio.get<ResponseBody>(
        '$base/second',
        options: Options(responseType: ResponseType.stream),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        requests,
        1,
        reason: 'response headers alone must not release the slot',
      );
      if (end == 'done') {
        release.complete();
        await first.data!.stream.drain<void>();
      } else if (end == 'cancel') {
        await subscription!.cancel();
      } else if (end == 'unread cancel') {
        cancel.cancel();
      } else {
        final failure = expectLater(
          first.data!.stream.drain<void>(),
          throwsA(anything),
        );
        release.complete();
        await failure;
      }
      final response = await second.timeout(const Duration(seconds: 2));
      await response.data!.stream.drain<void>();
      expect(requests, 2);
      if (!release.isCompleted) release.complete();
      cancel.cancel(); // Repeated termination must not return an extra slot.
      expect(await scheduler.run(() async => 42, host: '127.0.0.1'), 42);
    });
  }
}
