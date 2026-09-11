import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:baka/instance.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_dependencies.dart';

void main() {
  testWidgets('progress bar drag seeks to the finger position', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
    Instances.isTV = false;

    final controller = PlaybackController();
    controller.timeline.value = controller.timeline.value.copyWith(
      duration: const Duration(minutes: 24),
      position: const Duration(minutes: 20),
    );
    controller.setControlsVisible(true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BakaPlayer(controller: controller, full: true)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final progressBarFinder = find.byType(ProgressBar);
    expect(progressBarFinder, findsOneWidget);
    final rect = tester.getRect(progressBarFinder);
    final gesture = await tester.startGesture(
      Offset(rect.left + rect.width * 0.5, rect.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(Offset(rect.left + rect.width * 0.5, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));

    // 拖动条按手指位置 seek，而不是跳到结尾。
    expect(controller.timeline.value.position.inMinutes, 12);
    await controller.dispose();
  });
}
