import 'package:baka/core/account_session.dart';
import 'dart:async';
import 'package:baka/api/api_config.dart';
import 'package:baka/api/auth_api.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/core/http_request.dart';
import 'package:baka/services/account/login_service.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/api/playback.dart';
import 'package:baka/models/collection.dart';
import 'package:http/testing.dart';
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
      credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
    );
    addTearDown(apiTransport.close);
  });

  void useClient(http.Client client, {void Function(Object)? onError}) {
    apiTransport = ApiTransport(
      session: apiTransport.session,
      client: client,
      version: 'test',
      credentialOrigin: () => Uri.parse(ApiConfig.host),
      onError: onError,
    );
    addTearDown(client.close);
  }

  test(
    'HTTP, envelope, JSON and network failures retain distinct semantics',
    () async {
      var notices = 0;
      var status = 200;
      var body = '{}';
      final offline = http.ClientException('offline');
      useClient(
        MockClient((request) async {
          if (request.url.path == '/offline') throw offline;
          return http.Response(body, status);
        }),
        onError: (_) => notices++,
      );
      for (final code in [404, 500, 502, 503]) {
        status = code;
        body = '<html>upstream failure</html>';
        await expectLater(
          apiTransport.getJson<Map<String, dynamic>>(
            '$host/data',
            notifyOnError: false,
          ),
          throwsA(
            isA<ApiException>().having(
              (e) => e.statusCode,
              'HTTP status',
              code,
            ),
          ),
        );
      }
      status = 200;
      for (final invalid in ['', '<html>', 'null', '[]']) {
        body = invalid;
        await expectLater(
          apiTransport.getJson<Map<String, dynamic>>(
            '$host/data',
            notifyOnError: false,
          ),
          throwsFormatException,
        );
      }
      body = '{"code":403,"message":"denied"}';
      await expectLater(
        apiTransport.getData<Map<String, dynamic>>(
          '$host/data',
          notifyOnError: false,
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'envelope code', 403)
              .having((e) => e.statusCode, 'HTTP status', isNull),
        ),
      );
      body = '{"code":0}';
      await expectLater(
        apiTransport.getData<Map<String, dynamic>>(
          '$host/data',
          notifyOnError: false,
        ),
        throwsFormatException,
      );
      body = '{"code":0,"data":null}';
      expect(
        await apiTransport.getData<Map<String, dynamic>?>('$host/data'),
        isNull,
      );
      await expectLater(
        apiTransport.get('$host/offline', notifyOnError: false),
        throwsA(same(offline)),
      );
      expect(notices, 0);
      await expectLater(
        apiTransport.get('$host/offline'),
        throwsA(same(offline)),
      );
      expect(notices, 1);
    },
  );

  test(
    'missing post is distinct from malformed data and network failure',
    () async {
      var notices = 0;
      var body = '{"code":200,"data":null}';
      useClient(
        MockClient((request) async {
          expect(request.url.path, '/post/42');
          return http.Response(body, 200);
        }),
        onError: (_) => notices++,
      );

      await expectLater(
        getPostDetail(42),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'status', 404)
              .having((error) => error.message, 'message', '条目不存在或已删除'),
        ),
      );
      expect(notices, 0);
      for (final malformed in [
        '{"code":200}',
        '{"code":200,"data":[]}',
        '{"code":200,"data":"invalid"}',
      ]) {
        body = malformed;
        await expectLater(getPostDetail(42), throwsFormatException);
      }
      expect(notices, 3);
      body = '{"code":200,"data":{"id":42,"title":"Available"}}';
      expect((await getPostDetail(42))['id'], 42);
    },
  );

  test('post queries preserve signed URLs and omit null parameters', () async {
    final requests = <Uri>[];
    useClient(
      MockClient((request) async {
        requests.add(request.url);
        final body = switch (request.url.path) {
          '/play' => '{"code":200,"data":{"url":"https://media.test/video"}}',
          '/comment/uv' => '{"code":200,"msg":"liked"}',
          _ => '{"code":200,"data":[]}',
        };
        return http.Response(body, 200);
      }),
    );
    const signed = 'https://media.test/a.m3u8?x=1&sig=a%2Bb=c#part';
    expect(await getPlayUrl(signed), 'https://media.test/video');
    expect(requests.last.queryParameters, {'url': signed});
    await getSearch('中文 & x=y#z');
    expect(requests.last.queryParameters, {'key': '中文 & x=y#z'});
    await getSearch(null);
    expect(requests.last.queryParameters.containsKey('key'), isFalse);
    await getComments(null, 20, null);
    expect(requests.last.queryParameters, {'page': '1', 'pageSize': '20'});
    await getPost('动画&', '#tag', 1, 20);
    expect(requests.last.queryParameters['sort'], '动画&');
    expect(requests.last.queryParameters.containsKey('uid'), isFalse);
    expect(await updateCommentUv('a&b', null), 'liked');
    expect(requests.last.queryParameters, {'cid': 'a&b'});
    useClient(MockClient((_) async => http.Response('{"code":200}', 200)));
    await expectLater(updateCommentUv(1, 'name'), throwsFormatException);
  });

  test(
    'login and refresh share JSON/status handling without recursive auth',
    () async {
      useClient(
        MockClient((request) async {
          expect(request.headers['token'], isNull);
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (request.url.path == '/user/refresh') {
            expect(body, {'refresh_token': 'refresh'});
          } else {
            expect(body['name'], 'name');
          }
          return http.Response(
            jsonEncode({
              'code': 200,
              'token': 'new',
              'refresh_token': 'next',
              'user': {
                'id': 1,
                'name': 'name',
                'qq': '',
                'sign': '',
                'level': 0,
              },
            }),
            200,
          );
        }),
      );
      final result = await LoginService(
        apiTransport.session,
        apiTransport,
      ).performLogin(name: ' name ', pwd: 'password');
      expect(result.success, isTrue);
      expect(apiTransport.session.token, 'new');
      final auth = AuthApi(apiTransport.client, () => ApiConfig.host);
      expect((await auth.refresh('refresh'))?.token, 'new');
      useClient(MockClient((_) async => http.Response('rejected', 401)));
      expect(
        await AuthApi(apiTransport.client, () => ApiConfig.host).refresh('r'),
        isNull,
      );
      useClient(MockClient((_) async => http.Response('broken', 503)));
      await expectLater(
        AuthApi(apiTransport.client, () => ApiConfig.host).refresh('r'),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test(
    'credential requests refuse redirects and server changes invalidate detail cache',
    () async {
      var calls = 0;
      useClient(
        MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          if (request.url.path == '/redirect') {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://outside.test'},
            );
          }
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'server': request.url.host},
            }),
            200,
          );
        }),
      );
      await expectLater(
        apiTransport.get('$host/redirect'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 302)),
      );
      final first = await AniBakaApi.getAnimeDetail(543210);
      expect(await AniBakaApi.getAnimeDetail(543210), same(first));
      await Instances.sp.setString('host', 'other.test');
      final next = await AniBakaApi.getAnimeDetail(543210);
      expect(next?['server'], 'other.test');
      expect(calls, 3);
    },
  );

  test(
    'shared sender aborts a timeout while reading the response body',
    () async {
      final aborted = Completer<void>();
      final stream = StreamController<List<int>>();
      addTearDown(stream.close);
      final client = _StreamingClient((request) async {
        final abortable = request as http.AbortableRequest;
        abortable.abortTrigger!.then((_) {
          aborted.complete();
          stream.addError(http.RequestAbortedException(request.url));
          stream.close();
        });
        return http.StreamedResponse(stream.stream, 200);
      });
      await expectLater(
        sendHttp(
          client,
          'GET',
          Uri.parse('https://example.test/slow'),
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await aborted.future;
    },
  );

  test(
    'Bangumi keeps its own credentials and preserves 404/204 semantics',
    () async {
      final api = BangumiApi(
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer bgm-token');
          expect(request.headers['token'], isNull);
          expect(
            request.headers['user-agent'],
            contains('AniBakaBaka/AniBaka/'),
          );
          if (request.url.path == '/v0/me') {
            return http.Response('{"username":"bgm","nickname":"name"}', 200);
          }
          if (request.method == 'GET') {
            return http.Response('{"title":"missing"}', 404);
          }
          return http.Response('', 204);
        }),
      );
      addTearDown(api.close);
      expect((await api.getMe('bgm-token')).username, 'bgm');
      expect(await api.getCollection('bgm-token', 1), isNull);
      await api.putCollection(
        'bgm-token',
        AnimeCollection(bgmId: 1, status: 3),
      );
    },
  );

  test('OAuth stops on completion, cancellation and deadline', () async {
    var requests = 0;
    useClient(
      MockClient((_) async {
        requests++;
        return http.Response(
          '{"code":0,"data":{"status":"complete","access_token":"bgm"}}',
          200,
        );
      }),
    );
    const broker = BangumiOAuthBroker();
    expect((await broker.waitForCompletion('state')).accessToken, 'bgm');
    expect(requests, 1);

    for (final timeout in [false, true]) {
      final started = Completer<void>();
      useClient(
        _StreamingClient((request) async {
          started.complete();
          await (request as http.AbortableRequest).abortTrigger;
          throw http.RequestAbortedException(request.url);
        }),
      );
      final abort = Completer<void>();
      final result = broker.waitForCompletion(
        'state',
        abortTrigger: abort.future,
        timeout: timeout
            ? const Duration(milliseconds: 10)
            : const Duration(minutes: 10),
      );
      final assertion = expectLater(
        result,
        throwsA(
          timeout
              ? isA<TimeoutException>()
              : isA<http.RequestAbortedException>(),
        ),
      );
      await started.future;
      if (!timeout) abort.complete();
      await assertion;
    }
  });

  test(
    'leaving OAuth login aborts its request without connecting Bangumi',
    () async {
      final pollStarted = Completer<void>();
      useClient(
        _StreamingClient((request) async {
          if (request.url.path.endsWith('/start')) {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  '{"code":0,"data":{"authorization_url":"https://bgm.tv/oauth","state":"state"}}',
                ),
              ),
              200,
            );
          }
          pollStarted.complete();
          await (request as http.AbortableRequest).abortTrigger;
          throw http.RequestAbortedException(request.url);
        }),
      );
      final api = BangumiApi(
        client: MockClient(
          (_) async => throw StateError('must not fetch account'),
        ),
      );
      addTearDown(api.close);
      final session = BangumiSession(
        Instances.sp,
        apiTransport.session,
        api,
        const BangumiOAuthBroker(),
      );
      final login = await session.beginOAuthLogin();
      final complete = session.completeOAuthLogin(login.state);
      final assertion = expectLater(
        complete,
        throwsA(isA<http.RequestAbortedException>()),
      );
      await pollStarted.future;
      session.cancelOAuthLogin();
      await assertion;
      expect(session.isConnected, isFalse);
    },
  );

  test(
    'BGM lookup does not mutate input and failed searches can be retried',
    () async {
      final data = Map<String, dynamic>.unmodifiable({
        'title': '',
        'content': '<img src="https://image.test/cover.jpg">',
      });
      expect((await resolveBgmFromData(data)).subjectId, isNull);
      var attempts = 0;
      useClient(
        MockClient(
          (_) async => ++attempts == 1
              ? http.Response('offline', 503)
              : http.Response('{"data":[]}', 200),
        ),
      );
      await expectLater(
        searchBgmSubjects('retry-regression'),
        throwsA(isA<ApiException>()),
      );
      expect(await searchBgmSubjects('retry-regression'), isEmpty);
      expect(attempts, 2);
    },
  );

  test('character consumers share only pending requests by subject', () async {
    var calls = 0;
    useClient(
      MockClient((request) async {
        calls++;
        return http.Response('[]', 200);
      }),
    );
    final results = await Future.wait([
      getBgmCharacters(99801),
      getBgmCharacters(99801),
      getBgmCharacters(99802),
    ]);
    expect(calls, 2);
    expect(results[0], same(results[1]));
    await getBgmCharacters(99801);
    expect(calls, 3, reason: 'Large character responses are not retained');
  });

  test('POST timeout returns without waiting for the server', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    // Leave the response pending so only the client's timeout can finish it.
    server.listen((request) {});

    final result = apiTransport.post(
      'http://${server.address.address}:${server.port}/slow',
      const {'value': 1},
      timeout: const Duration(milliseconds: 50),
      notifyOnError: false,
    );

    await expectLater(result, throwsA(isA<TimeoutException>()));
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

    expect(result['data'], {'value': 7});
  });
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handle);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handle(request);
}
