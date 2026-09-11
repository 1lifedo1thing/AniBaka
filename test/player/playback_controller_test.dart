import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_dependencies.dart';

class _DanmakuSyncCounter implements DanmakuListener {
  int syncCount = 0;
  Duration lastPosition = Duration.zero;

  @override
  void onDanmakuTimeSync(Duration position) {
    syncCount++;
    lastPosition = position;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
  });

  tearDown(() {
    Instances.isTV = false;
  });

  test('controls visibility and lock state transitions', () {
    final controller = PlaybackController();
    expect(controller.overlay.value.controlsVisible, isFalse);

    controller.setControlsVisible(true);
    expect(controller.overlay.value.controlsVisible, isTrue);

    controller.toggleControls();
    expect(controller.overlay.value.controlsVisible, isFalse);

    controller.setControlsLocked(true);
    expect(controller.overlay.value.controlsLocked, isTrue);
    expect(controller.overlay.value.controlsVisible, isFalse);

    // When locked, toggleControls does not show controls
    controller.toggleControls();
    expect(controller.overlay.value.controlsVisible, isFalse);

    controller.setControlsLocked(false);
    expect(controller.overlay.value.controlsLocked, isFalse);
    expect(controller.overlay.value.controlsVisible, isTrue);

    controller.dispose();
  });

  test('volume and brightness clamping', () {
    final controller = PlaybackController();

    controller.setVolume(1.5);
    expect(controller.overlay.value.volume, 1.0);

    controller.setVolume(-0.5);
    expect(controller.overlay.value.volume, 0.0);

    controller.setVolume(0.7);
    expect(controller.overlay.value.volume, 0.7);

    controller.setBrightness(2.0);
    expect(controller.overlay.value.brightness, 1.0);

    controller.setBrightness(-1.0);
    expect(controller.overlay.value.brightness, 0.0);

    controller.setBrightness(0.4);
    expect(controller.overlay.value.brightness, 0.4);

    controller.dispose();
  });

  test('seek preview tracks position and bumps toast revision', () {
    final controller = PlaybackController();
    final initialRevision = controller.toastRevision.value;

    controller.beginSeekPreview();
    expect(controller.timeline.value.seeking, isTrue);
    expect(controller.toastRevision.value, initialRevision + 1);

    controller.updateSeekPreview(const Duration(seconds: 42));
    expect(controller.timeline.value.previewPosition, const Duration(seconds: 42));
    expect(controller.toastRevision.value, initialRevision + 2);

    controller.endSeekPreview();
    expect(controller.timeline.value.seeking, isFalse);
    expect(controller.toastRevision.value, initialRevision + 3);
    expect(controller.overlay.value.controlsVisible, isTrue);

    controller.dispose();
  });

  test('danmaku attachment synchronizes time and rate', () {
    final controller = PlaybackController();
    final danmaku = DanmakuController();
    final counter = _DanmakuSyncCounter();
    danmaku.attach(counter);

    controller.timeline.value = controller.timeline.value.copyWith(
      duration: const Duration(minutes: 20),
      position: const Duration(minutes: 5),
    );
    controller.core.value = controller.core.value.copyWith(playbackRate: 1.5);

    controller.attachDanmaku(danmaku);
    expect(danmaku.playbackRate, 1.5);
    expect(counter.lastPosition, const Duration(minutes: 5));

    controller.detachDanmaku();
    danmaku.detach(counter);
    controller.dispose();
  });

  test('jump prompt triggers on positive remembered positions', () {
    final controller = PlaybackController();
    expect(controller.overlay.value.showJumpPrompt, isFalse);

    controller.showJumpToPositionPrompt(const Duration(minutes: 3, seconds: 15));
    expect(controller.overlay.value.showJumpPrompt, isTrue);
    expect(controller.overlay.value.jumpPosition, const Duration(minutes: 3, seconds: 15));
    expect(controller.overlay.value.jumpPromptText, contains('03:15'));

    controller.hideJumpPrompt();
    expect(controller.overlay.value.showJumpPrompt, isFalse);
    expect(controller.overlay.value.jumpPosition, Duration.zero);

    controller.dispose();
  });

  test('double speed long press gestures update rate and overlay', () {
    final controller = PlaybackController();
    controller.preferences.value = controller.preferences.value.copyWith(
      longPressSpeed: 3.0,
    );

    controller.setDoubleSpeed(true);
    expect(controller.overlay.value.doubleSpeed, isTrue);
    expect(controller.overlay.value.longPressRate, 3.0);

    controller.updateDoubleSpeedOffset(64.0);
    expect(controller.overlay.value.longPressRate, greaterThan(3.0));

    controller.setDoubleSpeed(false);
    expect(controller.overlay.value.doubleSpeed, isFalse);

    controller.dispose();
  });

  test('watch party locks user controls when connected as viewer', () async {
    final controller = PlaybackController();
    controller.timeline.value = controller.timeline.value.copyWith(
      duration: const Duration(minutes: 10),
    );

    await controller.configureWatchParty(connected: true, canControl: false);

    await controller.play();
    await controller.pause();
    await controller.seek(const Duration(seconds: 30));
    await controller.setRate(2.0);

    expect(controller.core.value.playing, isFalse);
    expect(controller.core.value.playbackRate, 1.0);
    expect(controller.timeline.value.position, Duration.zero);

    // Remote operations succeed
    await controller.seek(const Duration(seconds: 30), remote: true);
    expect(controller.timeline.value.position, const Duration(seconds: 30));

    await controller.setRate(1.05, roomCorrection: true);
    expect(controller.core.value.playbackRate, 1.05);

    await controller.dispose();
  });

  test('preference updates persist and update state', () async {
    final controller = PlaybackController();

    await controller.updatePreferences(
      controller.preferences.value.copyWith(
        autoFullscreen: true,
        longPressSpeed: 2.5,
        defaultDanmakuOff: true,
      ),
    );

    expect(controller.preferences.value.autoFullscreen, isTrue);
    expect(controller.preferences.value.longPressSpeed, 2.5);
    expect(controller.preferences.value.defaultDanmakuOff, isTrue);
    expect(Instances.sp.getBool('player_autoFullscreen'), isTrue);
    expect(Instances.sp.getDouble('player_longPressSpeed'), 2.5);

    await controller.dispose();
  });

  test('loadTechnicalInfo combines preference and diagnostic properties', () async {
    final controller = PlaybackController();
    await controller.updatePreferences(
      controller.preferences.value.copyWith(
        videoRenderer: 'gpu-next',
        hwdecMode: 'auto-safe',
        videoEnhancementMode: VideoEnhancementMode.medium,
      ),
      persist: false,
    );
    controller.enhancement.value = const VideoEnhancementState(
      requestedMode: VideoEnhancementMode.medium,
      appliedPipeline: VideoEnhancementPipeline.medium,
    );

    final info = await controller.loadTechnicalInfo();
    expect(info.rendererProfile, 'gpu-next');
    expect(info.hardwareDecodeMode, 'auto-safe');
    expect(info.requestedEnhancementMode, VideoEnhancementMode.medium);
    expect(info.appliedEnhancementPipeline, VideoEnhancementPipeline.medium);

    await controller.dispose();
  });

  test('sanitizePlaybackError removes sensitive filesystem and network traces', () {
    expect(
      sanitizePlaybackError(Exception('Failed to open C:\\Users\\secret\\video.mp4')),
      contains('Failed to open'),
    );
    expect(
      sanitizePlaybackError('Failed to open C:\\Users\\secret\\video.mp4'),
      isNot(contains('secret')),
    );
    expect(
      sanitizePlaybackError('Network connection refused (http://user:pass@127.0.0.1:8080/stream)'),
      isNot(contains('pass')),
    );
  });
}
