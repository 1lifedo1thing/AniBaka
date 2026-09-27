import 'package:baka/core/account_session.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/core/api_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final testHttpOverrides = HttpOverrides.current;

  setUpAll(() {
    HttpOverrides.global = null;
  });
  tearDownAll(() {
    HttpOverrides.global = testHttpOverrides;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    apiTransport = ApiTransport(
      session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
      client: http.Client(),
      version: 'test',
    );
    addTearDown(apiTransport.close);
  });

  test('POST timeout returns without waiting for the server', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    // Leave the response pending so only the client's timeout can finish it.
    server.listen((request) {});

    final result = await apiTransport.post(
      'http://${server.address.address}:${server.port}/slow',
      const {'value': 1},
      timeout: const Duration(milliseconds: 50),
      notifyOnError: false,
    );

    expect(result, isEmpty);
  });

  test('abortable POST keeps JSON request and response behavior', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'code': 0, 'data': body}));
      await request.response.close();
    });

    final result = await apiTransport.postJson<Map<String, dynamic>>(
      'http://${server.address.address}:${server.port}/echo',
      const {'value': 7},
      timeout: const Duration(seconds: 1),
      notifyOnError: false,
    );

    expect(result?['data'], {'value': 7});
  });
}
