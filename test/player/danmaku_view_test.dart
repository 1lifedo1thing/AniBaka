import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/theme.dart';
import 'package:baka/widgets/danmaku/view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('scroll track rejects overlap and accepts safe trailing gaps', () {
    final track = DanmakuScrollTrack();
    track.register(startMs: 0, width: 100, endMs: 8000, speed: 0.125);

    expect(track.canAccept(500, 0.1, 900), isFalse);
    expect(track.canAccept(900, 0.1, 900), isTrue);
    expect(track.canAccept(1000, 0.2, 900), isFalse);
    expect(track.canAccept(4000, 0.2, 900), isTrue);
  });

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

  testWidgets('current position can be replayed before the first layout', (
    tester,
  ) async {
    final controller = DanmakuController();
    controller.syncTime(const Duration(minutes: 18));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DanmakuView(controller: controller)),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

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
