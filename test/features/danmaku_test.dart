import 'package:baka/instance.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/theme.dart';
import 'package:baka/widgets/danmaku/view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ProbeDanmakuListener implements DanmakuListener {
  VoidCallback? onSync;
  Duration? lastPosition;
  final List<String> events = [];

  @override
  void onDanmakuTimeSync(Duration position) {
    lastPosition = position;
    events.add('sync:${position.inMilliseconds}');
    onSync?.call();
  }

  @override
  void onDanmakuInject(DanmakuItem item) {}
  @override
  void onDanmakuItemsChanged() {}
  @override
  void onDanmakuOptionChanged(DanmakuOption next, DanmakuOption previous) {}
  @override
  void onDanmakuPause() {}
  @override
  void onDanmakuPlaybackRateChanged(double rate) {}
  @override
  void onDanmakuReset() {
    lastPosition = null;
    events.add('reset');
  }

  @override
  void onDanmakuResume() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decode and cache', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
    });

    tearDown(() => DanmakuController.clearCache());

    test(
      'one malformed timestamp does not discard the rest of the episode',
      () {
        final items = DanmakuController.decodeDanmaku(
          '[{"m":"bad","p":"NaN,1,255"},{"m":"ok","p":"1,1,255"}]',
        );
        expect(items.single.text, 'ok');
      },
    );

    test(
      'cache enforces item and episode budgets and refreshes LRU order',
      () async {
        final episode = List.filled(20000, const DanmakuItem('x'));
        DanmakuController.cacheItems('1-1', episode);
        DanmakuController.cacheItems('2-1', episode);
        expect(
          await DanmakuController.fetchDanmaku(
            subjectId: 1,
            episodeIndex: 1,
            titles: const [],
          ),
          same(episode),
        );
        DanmakuController.cacheItems('3-1', episode);
        expect(DanmakuController.cachedKeys.toList(), ['1-1', '3-1']);
        expect(DanmakuController.cacheSize.items, 40000);

        const item = DanmakuItem('x');
        for (
          var index = 0;
          index < DanmakuController.maxCachedEpisodes + 1;
          index++
        ) {
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
      },
    );

    test('parses, filters and sorts only when input is out of order', () async {
      final items = DanmakuController.decodeDanmaku(
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
      final items = DanmakuController.decodeDanmaku(
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
      final raw = DanmakuController.encodeDanmaku([item]);
      final reparsed = DanmakuController.decodeDanmaku(raw);
      expect(reparsed.single.text, 'hello');
      expect(reparsed.single.time, 1250);
      expect(reparsed.single.type, 5);
      expect(reparsed.single.color, const Color(0xFF00FF00));
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

    test(
      'updates the font without discarding other danmaku settings',
      () async {
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
      },
    );

    test('keeps legacy settings aligned with the app default font', () async {
      await Instances.sp.setString('danmaku_settings', '{"fontSize":18}');
      final controller = DanmakuController();

      DanmakuController.loadSettings(controller);

      expect(controller.option.fontFamily, AppFonts.defaultFont);
    });
  });

  group('timeline and display', () {
    test('listener changes during dispatch preserve the current snapshot', () {
      final controller = DanmakuController();
      final first = _ProbeDanmakuListener();
      final second = _ProbeDanmakuListener();
      final third = _ProbeDanmakuListener();
      controller.attach(first);
      controller.attach(second);
      first.onSync = () {
        controller.detach(second);
        controller.attach(third);
      };
      controller.syncTime(const Duration(seconds: 1));
      controller.syncTime(const Duration(seconds: 2));
      expect(second.events, ['sync:1000']);
      expect(third.events, ['sync:1000', 'sync:2000']);
      controller.dispose();
    });

    testWidgets('fixed comments repaint on expiry and freeze while paused', (
      tester,
    ) async {
      final controller = DanmakuController();
      controller.updateOption(
        const DanmakuOption(fontFamily: AppFonts.systemFont),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: DanmakuView(controller: controller),
        ),
      );
      controller.addItem(const DanmakuItem('top', type: 5));
      await tester.pump();
      final painter = tester
          .widget<CustomPaint>(find.byType(CustomPaint))
          .painter!;
      var repaints = 0;
      void count() => repaints++;
      painter.addListener(count);
      await tester.pump(const Duration(seconds: 2));
      expect(repaints, 0);
      controller.pause();
      await tester.pump(const Duration(seconds: 10));
      expect(repaints, 0);
      controller.resume();
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(repaints, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      painter.removeListener(count);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('replacing the controller replays its time after reset', (
      tester,
    ) async {
      final first = DanmakuController();
      final second = DanmakuController();
      for (final controller in [first, second]) {
        controller.updateOption(
          const DanmakuOption(fontFamily: AppFonts.systemFont),
        );
      }
      Widget view(DanmakuController controller) => Directionality(
        textDirection: TextDirection.ltr,
        child: DanmakuView(controller: controller),
      );
      await tester.pumpWidget(view(first));
      second.syncTime(const Duration(seconds: 60));
      second.setItems(const [
        DanmakuItem('past', time: 0),
        DanmakuItem('current', time: 60000),
      ]);
      final texts = <String>[];
      void observe(ObjectEvent event) {
        if (event is ObjectCreated && event.object is TextPainter) {
          texts.add((event.object as TextPainter).text!.toPlainText());
        }
      }

      FlutterMemoryAllocations.instance.addListener(observe);
      await tester.pumpWidget(view(second));
      FlutterMemoryAllocations.instance.removeListener(observe);
      expect(texts, contains('current'));
      expect(texts, isNot(contains('past')));
      await tester.pumpWidget(const SizedBox.shrink());
      first.dispose();
      second.dispose();
    });

    test(
      'repeat window extends from the latest duplicate and evicts in O(1)',
      () {
        final window = DanmakuRepeatWindow();
        expect(window.shouldBlock('same', 0), isFalse);
        expect(window.shouldBlock('same', 9000), isTrue);
        expect(window.shouldBlock('same', 11000), isTrue);
        expect(window.shouldBlock('same', 22000), isFalse);
        expect(window.retainedEventCount, 1);
      },
    );

    test('paused controller still forwards seek synchronization', () {
      final controller = DanmakuController();
      final listener = _ProbeDanmakuListener();
      controller.attach(listener);
      controller.pause();
      controller.syncTime(const Duration(seconds: 42));
      expect(listener.lastPosition, const Duration(seconds: 42));
      controller.detach(listener);
    });

    test('reset keeps the current media time as the danmaku anchor', () {
      final controller = DanmakuController();
      final listener = _ProbeDanmakuListener();
      controller.syncTime(const Duration(minutes: 18));
      controller.attach(listener);
      listener.events.clear();

      controller.reset();

      expect(listener.events, ['reset', 'sync:1080000']);
      expect(listener.lastPosition, const Duration(minutes: 18));
      controller.detach(listener);
    });

    test('inline view keeps time sync after fullscreen listener detaches', () {
      final controller = DanmakuController();
      final inline = _ProbeDanmakuListener();
      final fullscreen = _ProbeDanmakuListener();

      controller.syncTime(const Duration(seconds: 12));
      controller.attach(inline);
      controller.attach(fullscreen);
      expect(inline.lastPosition, const Duration(seconds: 12));
      expect(fullscreen.lastPosition, const Duration(seconds: 12));

      controller.syncTime(const Duration(seconds: 48));
      controller.detach(fullscreen);
      controller.syncTime(const Duration(seconds: 49));

      expect(inline.lastPosition, const Duration(seconds: 49));
      expect(fullscreen.lastPosition, const Duration(seconds: 48));
      controller.detach(inline);
    });

    testWidgets('idle timeline gaps do not schedule continuous frames', (
      tester,
    ) async {
      final controller = DanmakuController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 450,
              child: DanmakuView(controller: controller),
            ),
          ),
        ),
      );
      controller.setItems(const [DanmakuItem('future', time: 60000)]);
      controller.syncTime(Duration.zero);
      await tester.pump();

      expect(tester.binding.hasScheduledFrame, isFalse);

      controller.syncTime(const Duration(seconds: 60));
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);

      controller.pause();
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      final listener = _ProbeDanmakuListener();
      expect(() => controller.attach(listener), returnsNormally);
      controller.detach(listener);
    });
  });
}
