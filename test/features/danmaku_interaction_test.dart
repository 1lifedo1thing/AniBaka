import 'dart:async';
import 'dart:convert';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/setting/danmaku_settings_page.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/widgets/danmaku/danmaku_list_sheet.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('settings', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
    });

    Future<DanmakuController> openPanel(
      WidgetTester tester,
      Size size, {
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final controller = DanmakuController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF0077B6),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => DanmakuSettingsPage.show(context, controller),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets(
      'danmaku types remain independent and persist, blocking words stay editable',
      (tester) async {
        final controller = await openPanel(tester, const Size(1440, 1024));
        await tester.drag(find.byType(Slider).first, const Offset(-160, 0));
        await tester.pumpAndSettle();
        expect(controller.option.area, lessThan(1));
        expect(
          (jsonDecode(Instances.sp.getString('danmaku_settings')!)
              as Map)['area'],
          controller.option.area,
        );
        await tester.tap(find.text('顶部'));
        await tester.pumpAndSettle();
        expect(controller.option.hideTop, isTrue);
        expect(controller.option.hideBottom, isFalse);
        expect(controller.option.hideScroll, isFalse);
        final saved =
            jsonDecode(Instances.sp.getString('danmaku_settings')!) as Map;
        expect(saved['hideTop'], isTrue);
        await tester.tap(find.text('屏蔽重复弹幕'));
        await tester.pumpAndSettle();
        expect(controller.blockRepeat, isTrue);
        expect(Instances.sp.getBool('danmaku_block_repeat'), isTrue);
        await tester.enterText(find.byType(TextField), '剧透');
        await tester.tap(find.byTooltip('添加屏蔽词'));
        await tester.pumpAndSettle();
        expect(controller.blockWords, ['剧透']);
        expect(jsonDecode(Instances.sp.getString('danmaku_block_words')!), [
          '剧透',
        ]);
        await tester.tap(find.byTooltip('移除屏蔽词'));
        await tester.pumpAndSettle();
        expect(controller.blockWords, isEmpty);
        await tester.tap(find.byTooltip('关闭设置'));
        await tester.pumpAndSettle();
        expect(find.byType(PanelContainer), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    for (final size in [const Size(360, 800), const Size(844, 390)]) {
      testWidgets(
        'panel scrolls and closes at $size with large text and keyboard',
        (tester) async {
          await openPanel(tester, size, textScale: 1.5);
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('展开更多设置'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('展开更多设置'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byType(DropdownButton<String>));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.scrollUntilVisible(
            find.byType(TextField),
            180,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byType(TextField));
          tester.view.viewInsets = const FakeViewPadding(bottom: 140);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byTooltip('关闭设置').hitTestable(), findsOneWidget);
          tester.view.resetViewInsets();
          await tester.tap(find.byTooltip('关闭设置'));
          await tester.pumpAndSettle();
          expect(find.byType(PanelContainer), findsNothing);
        },
      );
    }
  });

  group('search and selection', () {
    testWidgets(
      'latest search and episode selection win out-of-order replies',
      (tester) async {
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
          session: AccountSession(
            preferences,
            refreshTokens: (_) async => null,
          ),
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
        episodes['91002']!.complete(
          http.Response('{"data":[{"sort":3}]}', 200),
        );
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
      },
    );
  });
}
