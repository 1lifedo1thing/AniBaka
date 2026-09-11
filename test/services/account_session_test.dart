import 'dart:async';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/models/app_user.dart';
import 'package:baka/models/token_response.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = AppUser(id: 1, name: 'one', qq: '', sign: '', level: 0);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'usertoken': 'old',
      'refresh_token': 'refresh',
    });
    prefs = await SharedPreferences.getInstance();
  });

  test(
    'concurrent unauthorized requests refresh once and retry once',
    () async {
      var refreshes = 0, requests = 0;
      final session = AccountSession(
        prefs,
        refreshTokens: (_) async {
          refreshes++;
          return const TokenResponse('new');
        },
      );
      final client = ApiTransport(
        session: session,
        version: 'test',
        client: MockClient((r) async {
          requests++;
          return http.Response(
            r.headers['token'] == 'new' ? 'ok' : '',
            r.headers['token'] == 'new' ? 200 : 401,
          );
        }),
      );
      expect(
        await Future.wait(
          List.generate(32, (_) => client.get('https://example.test/data')),
        ),
        everyElement('ok'),
      );
      expect(refreshes, 1);
      expect(requests, 64);
    },
  );

  test('logout while refreshing cannot restore old credentials', () async {
    final pending = Completer<TokenResponse?>();
    final started = Completer<void>();
    final session = AccountSession(
      prefs,
      refreshTokens: (_) {
        started.complete();
        return pending.future;
      },
    );
    final refreshing = session.refresh();
    await started.future;
    await session.logout();
    pending.complete(const TokenResponse('stale', refreshToken: 'stale'));
    expect(await refreshing, isFalse);
    await session.flush();
    expect(session.token, isEmpty);
    expect(prefs.getString('usertoken'), isNull);
    expect(prefs.getString('refresh_token'), isNull);
  });

  test('response from the previous account is discarded', () async {
    final response = Completer<http.Response>();
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final client = ApiTransport(
      session: session,
      version: 'test',
      client: MockClient((_) => response.future),
    );
    final request = client.get('https://example.test/private');
    await session.login(const TokenResponse('other'), user);
    response.complete(http.Response('old account data', 200));
    expect(await request, isEmpty);
    expect(session.token, 'other');
  });

  test('credential writes finish in account transition order', () async {
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    final first = session.login(
      const TokenResponse('one', refreshToken: 'r'),
      user,
    );
    final second = session.logout();
    final third = session.login(const TokenResponse('three'), user);
    await Future.wait([first, second, third]);
    expect(prefs.getString('usertoken'), 'three');
    expect(prefs.getString('refresh_token'), isNull);
  });

  test(
    'missing or failing refresh can be tried again without a stuck future',
    () async {
      var calls = 0;
      final session = AccountSession(
        prefs,
        refreshTokens: (_) async {
          if (++calls == 1) throw StateError('offline');
          return const TokenResponse('new');
        },
      );
      expect(await session.refresh(), isFalse);
      expect(await session.refresh(), isTrue);
      expect(calls, 2);
    },
  );
}
