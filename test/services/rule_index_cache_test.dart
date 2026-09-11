import '../support/app_dependencies.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:baka/instance.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'index requests share parsing, refresh, offline data and removal',
    () async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      configureTestServices();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final url = 'http://127.0.0.1:${server.port}/index.json';
      final service = ruleRepository;
      await service.addSubscription(url);
      var calls = 0;
      var fail = false;
      Completer<void>? gate;
      final received = StreamController<void>.broadcast();
      addTearDown(received.close);
      final body = jsonEncode({
        'format': 'anx-rulehub/2',
        'entries': [
          {'key': 'test', 'title': 'Test', 'ref': 'test.json', 'rev': 1},
        ],
      });
      server.listen((request) async {
        calls++;
        received.add(null);
        await gate?.future;
        request.response.statusCode = fail ? 503 : 200;
        request.response.write(body);
        await request.response.close();
      });
      final indexes = await Future.wait([
        for (var i = 0; i < 20; i++) service.fetchIndex(url),
      ]);
      expect(calls, 1);
      expect(indexes.every((value) => identical(value, indexes.first)), isTrue);
      await service.fetchIndex(url);
      expect(calls, 1);
      await Future.wait([
        for (var i = 0; i < 20; i++)
          service.fetchIndex(url, forceRefresh: true),
      ]);
      expect(calls, 2);
      fail = true;
      expect(
        (await service.fetchIndex(url, forceRefresh: true)).rules.single.id,
        'test',
      );
      expect(calls, 3);
      fail = false;
      gate = Completer<void>();
      final started = received.stream.first;
      final old = service.fetchIndex(url, forceRefresh: true);
      await started;
      await service.removeSubscription(url);
      gate.complete();
      await old;
      expect(Instances.sp.getString('rule_hub_cache:$url'), isNull);
      await service.fetchIndex(url);
      expect(calls, 5);
    },
  );
}
