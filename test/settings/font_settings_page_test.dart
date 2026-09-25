import 'dart:convert';

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/setting/font_settings_page.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
// Use the package's test hooks to keep font resolution real and I/O offline.
// ignore: implementation_imports
import 'package:google_fonts/src/google_fonts_base.dart' as fonts;
import 'package:shared_preferences/shared_preferences.dart';

class _FontAssets extends Fake implements AssetManifest {
  @override
  List<String> listAssets() => [
    for (final name in AppFonts.fontOptions.keys)
      for (final weight in [
        'Thin',
        'ExtraLight',
        'Light',
        'Regular',
        'Medium',
        'SemiBold',
        'Bold',
        'ExtraBold',
        'Black',
      ])
        '${name.replaceAll(' ', '')}-$weight.ttf',
  ];
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    Get.put(AppState());
    GoogleFonts.config.allowRuntimeFetching = false;
    fonts.assetManifest = _FontAssets();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final key = utf8.decode(message!.buffer.asUint8List());
          return key.endsWith('.ttf') ? ByteData(0) : null;
        });
  });

  tearDown(() {
    Get.reset();
    fonts.clearCache();
    fonts.assetManifest = null;
    GoogleFonts.config.allowRuntimeFetching = true;
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: FontSettingsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('preview is live; scale, weight and both font choices persist', (
    tester,
  ) async {
    await open(tester);
    final state = Get.find<AppState>();
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(1.2);
    await tester.pump();
    expect(state.fontScale, 1);
    expect(tester.widget<Text>(find.text('命运石之门')).style!.fontSize, 26.4);
    slider.onChangeEnd!(1.2);
    expect(Instances.sp.getDouble(AppFonts.fontScaleKey), 1.2);
    final chip = find.widgetWithText(ChoiceChip, '粗体 W700');
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pump();
    expect(state.fontWeight, FontWeight.w700);
    expect(Instances.sp.getInt(AppFonts.fontWeightKey), 6);
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    dropdown.onChanged!(AppFonts.systemFont);
    await tester.pump();
    expect(DanmakuController.getSavedFontFamily(), AppFonts.systemFont);
    final system = find.widgetWithText(ListTile, '跟随系统');
    await tester.scrollUntilVisible(system, 250);
    await tester.tap(system);
    await tester.pumpAndSettle();
    expect(state.fontFamily, AppFonts.systemFont);
    expect(Instances.sp.getString(AppFonts.spKey), AppFonts.systemFont);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(), home: const FontSettingsPage()),
    );
    await tester.pumpAndSettle();
    var preview = tester.widget<Text>(find.text('命运石之门')).style!;
    expect(preview.fontFamily, isNull);
    expect(preview.fontSize, 26.4);
    expect(preview.fontWeight, FontWeight.w700);
    expect(preview.color, Colors.white);
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .value,
      AppFonts.systemFont,
    );
    state.setFontFamily('Noto Sans SC');
    await tester.pumpAndSettle();
    preview = tester.widget<Text>(find.text('命运石之门')).style!;
    expect(preview.fontFamily, contains('NotoSansSC'));
    expect(preview.fontWeight, FontWeight.w700);
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.light(), home: const FontSettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('命运石之门')).style!.color, Colors.black);
    expect(tester.takeException(), isNull);
  });

  testWidgets('benchmark live scale updates on the real page', (tester) async {
    await open(tester);
    var rebuilt = 0;
    var fontFutures = 0;
    var measuring = false;
    debugOnRebuildDirtyWidget = (_, _) {
      if (measuring) rebuilt++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    Future<void> step(int i) async {
      tester.widget<Slider>(find.byType(Slider)).onChanged!(
        i.isEven ? 0.9 : 1.2,
      );
      tester.binding.addPostFrameCallback((_) {
        if (measuring) fontFutures += fonts.pendingFontFutures.length;
      });
      await tester.pump(const Duration(milliseconds: 16));
    }

    for (var i = 0; i < 100; i++) {
      await step(i);
    }
    final samples = <int>[];
    measuring = true;
    for (var sample = 0; sample < 7; sample++) {
      final timer = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        await step(i);
      }
      samples.add(timer.elapsedMicroseconds);
    }
    measuring = false;
    samples.sort();
    // Debug widget-test elapsed time, not device frame time or RSS.
    debugPrint(
      'FONT_BENCH ${jsonEncode({'samples_us_per_100_updates': samples, 'median_us_per_update': samples[3] / 100, 'rebuilt_widgets_per_update': rebuilt / 700, 'pending_font_futures_per_frame': fontFutures / 700})}',
    );
    expect(Get.find<AppState>().fontScale, 1);
    expect(tester.takeException(), isNull);
  });
}
