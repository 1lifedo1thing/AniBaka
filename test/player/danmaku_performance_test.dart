import 'dart:convert';

import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/theme.dart';
import 'package:baka/widgets/danmaku/view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixed Flutter Test/Debug workload, not device CPU/GPU profiling.
void main() {
  testWidgets('danmaku fixed workload benchmark', (tester) async {
    final emission = <int>[];
    final sparse = <int>[];
    final sync = <int>[];
    final decode = <int>[];
    var textPaintersCreated = 0;
    var textPaintersDisposed = 0;
    void trackTextLayouts(ObjectEvent event) {
      if (event.object is! TextPainter) return;
      if (event is ObjectCreated) textPaintersCreated++;
      if (event is ObjectDisposed) textPaintersDisposed++;
    }

    final items = List.generate(
      3000,
      (i) => DanmakuItem('弹幕 $i abcdefghijklmnop'),
    );
    final raw = jsonEncode([
      for (var i = 0; i < 10000; i++)
        {'m': '弹幕 $i', 'p': '${i / 10},1,16777215'},
    ]);
    for (var run = 0; run < 9; run++) {
      final controller = DanmakuController();
      controller.updateOption(
        const DanmakuOption(fontFamily: AppFonts.systemFont, fontSize: 22),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 800,
              height: 450,
              child: DanmakuView(controller: controller),
            ),
          ),
        ),
      );
      final watch = Stopwatch()..start();
      if (run == 0) {
        FlutterMemoryAllocations.instance.addListener(trackTextLayouts);
      }
      for (final item in items) {
        controller.addItem(item);
      }
      if (run == 0) {
        FlutterMemoryAllocations.instance.removeListener(trackTextLayouts);
      }
      watch.stop();
      if (run >= 2) emission.add(watch.elapsedMicroseconds);
      controller.reset();
      watch.reset();
      watch.start();
      for (var i = 0; i < 12; i++) {
        controller.addItem(items[i]);
      }
      watch.stop();
      if (run >= 2) sparse.add(watch.elapsedMicroseconds);
      controller.reset();
      await tester.pumpWidget(const SizedBox.shrink());
      final first = _Listener();
      final second = _Listener();
      controller.attach(first);
      controller.attach(second);
      watch.reset();
      watch.start();
      for (var i = 0; i < 100000; i++) {
        controller.syncTime(Duration(milliseconds: i));
      }
      watch.stop();
      expect(first.position, const Duration(milliseconds: 99999));
      if (run >= 2) sync.add(watch.elapsedMicroseconds);
      controller.dispose();
      watch.reset();
      watch.start();
      final decoded = DanmakuController.decodeDanmaku(raw);
      watch.stop();
      expect(decoded.length, 10000);
      if (run >= 2) decode.add(watch.elapsedMicroseconds);
    }
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
    controller.addItem(const DanmakuItem('固定弹幕', type: 5));
    await tester.pump();
    final paints = find
        .byType(CustomPaint)
        .evaluate()
        .map((e) => (e.widget as CustomPaint).painter)
        .whereType<CustomPainter>()
        .toList();
    var repaints = 0;
    void onRepaint() => repaints++;
    for (final painter in paints) {
      painter.addListener(onRepaint);
    }
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (final painter in paints) {
      painter.removeListener(onRepaint);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    DanmakuController.clearCache();
    for (var i = 0; i < 5; i++) {
      DanmakuController.cacheItems(
        '$i',
        List.filled(50000, const DanmakuItem('cached')),
      );
    }
    int median(List<int> samples) => (samples..sort())[samples.length ~/ 2];
    // ignore: avoid_print
    print(
      'DANMAKU_BENCH ${jsonEncode({'emission_us': median(emission), 'sparse_us': median(sparse), 'sync_us': median(sync), 'decode_us': median(decode), 'fixed_repaints': repaints, 'cached_items': DanmakuController.cacheSize.items, 'text_painters_created': textPaintersCreated, 'text_painters_retained': textPaintersCreated - textPaintersDisposed, 'emission_samples': emission, 'sparse_samples': sparse, 'sync_samples': sync, 'decode_samples': decode})}',
    );
    DanmakuController.clearCache();
  });
}

class _Listener implements DanmakuListener {
  Duration? position;
  @override
  void onDanmakuTimeSync(Duration value) {
    position = value;
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
  void onDanmakuReset() {}
  @override
  void onDanmakuResume() {}
}
