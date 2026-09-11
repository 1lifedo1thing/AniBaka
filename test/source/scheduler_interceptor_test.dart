import 'dart:io';
import 'package:baka/source/runtime/scheduler_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cancelled Dio requests leave the queue without sending HTTP or leaking slots',
    () async {
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var received = 0;
      server.listen((request) async {
        received++;
        request.response.write('ok');
        await request.response.close();
      });
      final interceptor = SchedulerInterceptor();
      final scheduler = interceptor.scheduler;
      await scheduler.acquire('127.0.0.1');
      await scheduler.acquire('127.0.0.1');
      final dio = Dio()..interceptors.add(interceptor);
      addTearDown(() async {
        dio.close(force: true);
        await server.close(force: true);
      });
      final cancel = CancelToken();
      final request = dio.get<String>(
        'http://127.0.0.1:${server.port}/',
        cancelToken: cancel,
      );
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      await expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(received, 0);
      scheduler.release('127.0.0.1');
      scheduler.release('127.0.0.1');
      expect(
        (await dio.get<String>('http://127.0.0.1:${server.port}/')).data,
        'ok',
      );
      expect(received, 1);
    },
  );
}
