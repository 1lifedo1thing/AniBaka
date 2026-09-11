import 'dart:convert';

import 'package:baka/instance.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_dependencies.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
  });

  tearDown(() => DanmakuController.clearCache());

  test('parses, filters and sorts only when input is out of order', () async {
    final items = await DanmakuController.decode(
      '{"data":['
      '{"m":"later","p":"2.5,1,16711680"},'
      '{"m":"bottom","p":"1.0,4,255"},'
      '{"m":"","p":"0,1,1"},'
      '{"m":"unsupported","p":"0,8,1"}'
      ']}',
    );
    expect(items.map((item) => item.text), ['bottom', 'later']);
    expect(items.first.time, 1000);
    expect(items.first.type, 4);
    expect(items.last.color, const Color(0xFFFF0000));
  });

  test('parses color from standard parameters after font size', () async {
    final items = await DanmakuController.decode(
      '{"data":['
      '{"m":"white","p":"0.0,1,25,16777215,source"},'
      '{"m":"red","p":"1.0,1,25,16711680,source"}'
      ']}',
    );

    expect(items.map((item) => item.color), [
      const Color(0xFFFFFFFF),
      const Color(0xFFFF0000),
    ]);
  });

  test('serializes typed items for local download compatibility', () async {
    const item = DanmakuItem(
      'hello',
      time: 1250,
      type: 5,
      color: Color(0xFF00FF00),
    );
    final raw = DanmakuController.encode([item]);
    final reparsed = await DanmakuController.decode(raw);
    expect(reparsed.single.text, 'hello');
    expect(reparsed.single.time, 1250);
    expect(reparsed.single.type, 5);
    expect(reparsed.single.color, const Color(0xFF00FF00));
  });

  test('decodes large payloads through the worker path', () async {
    final raw = jsonEncode({
      'data': [
        for (var index = 0; index < 600; index++)
          {'m': 'large-$index', 'p': '${index / 10},1,16777215,0'},
      ],
    });
    expect(raw.length, greaterThan(16 * 1024));

    final items = await DanmakuController.decode(raw);
    expect(items, hasLength(600));
    expect(items.first.text, 'large-0');
    expect(items.last.text, 'large-599');
  });

  test('LRU cache enforces episode and item budgets', () {
    const item = DanmakuItem('x');
    for (var index = 0; index < DanmakuController.maxCachedEpisodes + 1; index++) {
      DanmakuController.cacheItems('episode-$index', const [item]);
    }
    expect(
      DanmakuController.cacheSize.episodes,
      DanmakuController.maxCachedEpisodes,
    );
    expect(DanmakuController.cachedKeys, isNot(contains('episode-0')));

    DanmakuController.clearCache();
    DanmakuController.cacheItems(
      'oversized',
      List<DanmakuItem>.filled(DanmakuController.maxCachedItems + 1, item),
    );
    expect(DanmakuController.cacheSize, (episodes: 0, items: 0));
  });

  test('persists and restores the selected danmaku font', () async {
    final controller = DanmakuController();
    controller.updateOption(
      controller.option.copyWith(fontFamily: 'Zen Maru Gothic'),
    );

    await DanmakuController.saveSettings(controller);
    final restored = DanmakuController();
    DanmakuController.loadSettings(restored);

    expect(restored.option.fontFamily, 'Zen Maru Gothic');
  });

  test('updates the font without discarding other danmaku settings', () async {
    await Instances.sp.setString(
      'danmaku_settings',
      '{"fontSize":26,"opacity":0.5}',
    );

    await DanmakuController.setFontFamily('Sawarabi Gothic');
    final controller = DanmakuController();
    DanmakuController.loadSettings(controller);

    expect(controller.option.fontFamily, 'Sawarabi Gothic');
    expect(controller.option.fontSize, 26);
    expect(controller.option.opacity, 0.5);
  });

  test('keeps legacy settings aligned with the app default font', () async {
    await Instances.sp.setString('danmaku_settings', '{"fontSize":18}');
    final controller = DanmakuController();

    DanmakuController.loadSettings(controller);

    expect(controller.option.fontFamily, AppFonts.defaultFont);
  });
}
