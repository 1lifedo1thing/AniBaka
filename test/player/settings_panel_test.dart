import 'dart:convert';

import 'package:baka/instance.dart';
import 'package:baka/pages/setting/danmaku_settings_page.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
}
