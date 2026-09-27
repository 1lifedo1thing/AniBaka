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
// ignore: implementation_imports
import 'package:google_fonts/src/google_fonts_base.dart' as fonts;
import 'package:shared_preferences/shared_preferences.dart';

// Use the package's test hooks to keep font resolution real and I/O offline.

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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('font preferences', () {
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

    testWidgets(
      'preview is live; scale, weight and both font choices persist',
      (tester) async {
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
        expect(
          tester
              .widget<DropdownButton<String>>(
                find.byType(DropdownButton<String>),
              )
              .value,
          AppFonts.systemFont,
        );
        state.setFontFamily('Noto Sans SC');
        await tester.pumpAndSettle();
        preview = tester.widget<Text>(find.text('命运石之门')).style!;
        expect(preview.fontFamily, contains('NotoSansSC'));
        expect(preview.fontWeight, FontWeight.w700);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('legacy fonts', () {
    late AppState state;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      state = AppState()..onInit();
    });

    tearDown(() => state.onClose());

    test('removed fonts fall back to the default font', () async {
      for (final font in ['Ma Shan Zheng', 'Noto Sans TC', 'Dela Gothic One']) {
        await Instances.sp.setString(AppFonts.spKey, font);

        final restored = AppState()..onInit();
        expect(restored.fontFamily, AppFonts.defaultFont);
        restored.onClose();
      }
    });
  });
}
