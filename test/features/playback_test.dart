import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/playback/media_session.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('controls', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
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

    test(
      'sanitizePlaybackError removes sensitive filesystem and network traces',
      () {
        expect(
          sanitizePlaybackError(
            Exception('Failed to open C:\\Users\\secret\\video.mp4'),
          ),
          contains('Failed to open'),
        );
        expect(
          sanitizePlaybackError('Failed to open C:\\Users\\secret\\video.mp4'),
          isNot(contains('secret')),
        );
        expect(
          sanitizePlaybackError(
            'Network connection refused (http://user:pass@127.0.0.1:8080/stream)',
          ),
          isNot(contains('pass')),
        );
      },
    );
  });

  group('media session', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
    });

    test(
      'media handler forwards commands and mirrors controller metadata',
      () async {
        final controller = PlaybackController();
        final handler = PlaybackAudioHandler();
        final service = MediaSessionService(audioHandler: handler);
        var nextCalls = 0;
        var previousCalls = 0;

        controller.setMediaInfo(
          const PlaybackMediaInfo(
            title: '作品',
            episode: '第 2 集',
            imageUrl: 'https://example.test/cover.jpg',
            episodeIndex: 1,
            totalEpisodes: 12,
          ),
        );
        service.attach(
          controller,
          onNextEpisode: () => nextCalls++,
          onPreviousEpisode: () => previousCalls++,
        );

        await handler.play();
        await handler.pause();
        await handler.setSpeed(1.5);
        controller.timeline.value = controller.timeline.value.copyWith(
          duration: const Duration(minutes: 24),
        );
        await handler.seek(const Duration(minutes: 3));
        await handler.skipToNext();
        await handler.skipToPrevious();

        expect(controller.core.value.playbackRate, 1.5);
        expect(controller.timeline.value.position, const Duration(minutes: 3));
        expect(nextCalls, 1);
        expect(previousCalls, 1);
        expect(handler.mediaItem.value?.title, '作品 - 第 2 集');
        expect(handler.mediaItem.value?.duration, const Duration(minutes: 24));

        service.detach();
        await controller.dispose();
      },
    );
  });

  group('ad filter preference', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
    });

    test('去广告开关在持久化后通知当前媒体重新处理，其他设置不触发', () async {
      final controller = PlaybackController();
      final changes = <bool>[];
      controller.onHlsAdFilterChanged = (enabled) async {
        expect(Instances.sp.getBool('player_filterHlsAds'), enabled);
        changes.add(enabled);
      };
      await controller.updatePreferences(
        controller.preferences.value.copyWith(filterHlsAds: true),
      );
      await controller.updatePreferences(
        controller.preferences.value.copyWith(showSystemTime: true),
      );
      await controller.updatePreferences(controller.preferences.value);
      await controller.updatePreferences(
        controller.preferences.value.copyWith(filterHlsAds: false),
      );
      expect(changes, [true, false]);
      await controller.dispose();
    });
  });
}
