import 'dart:async';
import 'dart:convert';

import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/widgets/danmaku/danmaku_list_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('latest search and episode selection win out-of-order replies', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final searches = <String, Completer<http.Response>>{};
    final loads = <String, Completer<http.Response>>{};
    final episodes = <String, Completer<http.Response>>{};
    final episodeCalls = <String, int>{};
    final client = MockClient((request) {
      if (request.url.path.contains('/search/subjects')) {
        final keyword = jsonDecode(request.body)['keyword'] as String;
        return (searches[keyword] = Completer<http.Response>()).future;
      }
      if (request.url.path == '/v0/episodes') {
        final id = request.url.queryParameters['subject_id']!;
        episodeCalls.update(id, (value) => value + 1, ifAbsent: () => 1);
        return (episodes[id] = Completer<http.Response>()).future;
      }
      final episode = request.url.queryParameters['p']!;
      return (loads[episode] = Completer<http.Response>()).future;
    });
    apiTransport = ApiTransport(
      session: AccountSession(preferences, refreshTokens: (_) async => null),
      client: client,
      version: 'test',
    );
    addTearDown(client.close);
    addTearDown(DanmakuController.clearCache);
    final controller = DanmakuController();
    var notifications = 0;
    controller.addListener(() => notifications++);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: DanmakuListSheet(
                controller: controller,
                defaultTitle: 'Alpha',
                initialShowSearch: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Beta');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    searches['Beta']!.complete(
      http.Response(
        jsonEncode({
          'data': [
            {
              'id': 91001,
              'name': 'Beta',
              'images': {},
              'rating': {'score': 0},
            },
            {
              'id': 91002,
              'name': 'Gamma',
              'images': {},
              'rating': {'score': 0},
            },
          ],
        }),
        200,
      ),
    );
    await tester.pump();
    await tester.pump();
    searches['Alpha']!.complete(
      http.Response(
        jsonEncode({
          'data': [
            {
              'id': 91003,
              'name': 'Old result',
              'images': {},
              'rating': {'score': 0},
            },
          ],
        }),
        200,
      ),
    );
    await tester.pump();
    expect(find.text('Old result'), findsNothing);
    await tester.tap(find.text('Gamma'));
    await tester.pump();
    episodes['91001']!.complete(
      http.Response('{"data":[{"sort":1},{"sort":2}]}', 200),
    );
    await tester.pump();
    expect(find.text('E1'), findsNothing);
    episodes['91002']!.complete(http.Response('{"data":[{"sort":3}]}', 200));
    await tester.pumpAndSettle();
    expect(find.text('E3'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Beta'));
    await tester.pumpAndSettle();
    expect(episodeCalls, {'91001': 1, '91002': 1});
    await tester.tap(find.text('E1'));
    await tester.pump();
    await tester.tap(find.text('E2'));
    await tester.pump();
    loads['2']!.complete(
      http.Response('[{"m":"latest","p":"1,1,16777215"}]', 200),
    );
    await tester.pump();
    loads['1']!.complete(
      http.Response('[{"m":"stale","p":"1,1,16777215"}]', 200),
    );
    await tester.pumpAndSettle();
    expect(controller.items.single.text, 'latest');
    expect(notifications, 1);
    expect(find.text('手动检索'), findsOneWidget);
    await tester.tap(find.text('+0.5s'));
    await tester.pumpAndSettle();
    expect(controller.timeOffset, 0.5);
    expect(find.text('延迟 0.5s'), findsOneWidget);
    controller.setTimeOffset(-1);
    await tester.pump();
    expect(find.text('延迟 -1.0s'), findsOneWidget);
    await tester.tap(find.text('重置'));
    await tester.pump();
    expect(controller.timeOffset, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
