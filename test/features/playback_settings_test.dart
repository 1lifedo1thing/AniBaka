import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('preferences and migration', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
    });

    test(
      'changed preferences survive reload without rewriting legacy keys',
      () async {
        const previous = PlaybackPreferences();
        final next = previous.copyWith(
          autoFullscreen: true,
          longPressSpeed: 2.5,
          videoEnhancementMode: VideoEnhancementMode.medium,
          lastVideoEnhancementMode: VideoEnhancementMode.medium,
          subtitleConfig: previous.subtitleConfig.copyWith(fontSize: 32),
        );
        await PlaybackSettingsService.saveChanges(previous, next);

        final restored = PlaybackSettingsService.loadAll();
        expect(restored.autoFullscreen, isTrue);
        expect(restored.longPressSpeed, 2.5);
        expect(restored.videoEnhancementMode, VideoEnhancementMode.medium);
        expect(restored.lastVideoEnhancementMode, VideoEnhancementMode.medium);
        expect(restored.subtitleConfig.fontSize, 32);
        expect(Instances.sp.containsKey('player_enableAnime4K'), isFalse);
        expect(Instances.sp.containsKey('player_anime4KLevel'), isFalse);

        await Instances.sp.clear();
        await PlaybackSettingsService.saveChanges(previous, previous);
        expect(Instances.sp.getKeys(), isEmpty);
      },
    );

    test('persists and migrates the video renderer selection', () async {
      const previous = PlaybackPreferences();
      final next = previous.copyWith(videoRenderer: 'gpu-next');

      await PlaybackSettingsService.saveChanges(previous, next);

      expect(Instances.sp.getString('player_videoRenderer'), 'gpu-next');
      expect(PlaybackSettingsService.normalizeVideoRenderer('auto'), 'gpu');
      expect(
        PlaybackSettingsService.normalizeVideoRenderer('compatibility'),
        'gpu',
      );
      expect(
        PlaybackSettingsService.normalizeVideoRenderer('quality'),
        'gpu-next',
      );
      expect(PlaybackSettingsService.normalizeVideoRenderer('gpu'), 'gpu');
      expect(
        PlaybackSettingsService.normalizeVideoRenderer('gpu-next'),
        'gpu-next',
      );
      expect(
        PlaybackSettingsService.normalizeVideoRenderer('mediacodec_embed'),
        'mediacodec_embed',
      );
      expect(PlaybackSettingsService.normalizeVideoRenderer(null), 'gpu');

      // Android 上无法使用 gpu-next/quality，一律回落到 gpu。
      expect(
        PlaybackSettingsService.normalizeVideoRenderer(
          'gpu-next',
          android: true,
        ),
        'gpu',
      );
      expect(
        PlaybackSettingsService.normalizeVideoRenderer(
          'quality',
          android: true,
        ),
        'gpu',
      );
      expect(
        PlaybackSettingsService.normalizeVideoRenderer(
          'mediacodec_embed',
          android: true,
        ),
        'mediacodec_embed',
      );
      expect(
        PlaybackSettingsService.normalizeVideoRenderer(null, android: true),
        'gpu',
      );
    });

    test(
      'migrates enabled legacy Anime4K levels to the same named levels',
      () async {
        SharedPreferences.setMockInitialValues({
          'player_enableAnime4K': true,
          'player_anime4KLevel': 'high',
        });
        Instances.sp = await SharedPreferences.getInstance();

        final preferences = PlaybackSettingsService.loadAll();

        expect(preferences.videoEnhancementMode, VideoEnhancementMode.high);
        expect(preferences.lastVideoEnhancementMode, VideoEnhancementMode.high);
      },
    );

    test('keeps legacy disabled while remembering its migrated mode', () async {
      SharedPreferences.setMockInitialValues({
        'player_enableAnime4K': false,
        'player_anime4KLevel': 'ultra',
      });
      Instances.sp = await SharedPreferences.getInstance();

      final preferences = PlaybackSettingsService.loadAll();

      expect(preferences.videoEnhancementMode, VideoEnhancementMode.off);
      expect(preferences.lastVideoEnhancementMode, VideoEnhancementMode.ultra);
    });
  });

  group('renderer configuration', () {
    test('mediacodec_embed pins hwdec but never sets vo on initial load', () {
      final properties = buildPlayerProperties(
        videoRenderer: 'mediacodec_embed',
        android: true,
      );

      expect(properties['hwdec'], 'mediacodec');
      expect(properties, isNot(contains('vo')));
      expect(properties, isNot(contains('vid')));
    });

    test(
      'effectiveHwdec forces mediacodec only for direct renderer on Android',
      () {
        expect(
          effectiveHwdec('auto-safe', 'mediacodec_embed', android: true),
          'mediacodec',
        );
        expect(
          effectiveHwdec('no', 'mediacodec_embed', android: true),
          'mediacodec',
        );
        expect(effectiveHwdec('no', 'mediacodec_embed', android: false), 'no');
        expect(effectiveHwdec('no', 'gpu-next', android: true), 'no');
        expect(effectiveHwdec('auto', 'gpu', android: true), 'auto-safe');
        expect(effectiveHwdec('auto', 'gpu', android: false), 'auto');
        expect(
          effectiveHwdec('mediacodec-copy', 'gpu', android: true),
          'mediacodec-copy',
        );
      },
    );

    test('codec open failures are fatal even when audio is still playing', () {
      expect(isFatalPlaybackError('Could not open codec.'), isTrue);
      expect(isFatalPlaybackError('Failed to open codec: h264'), isTrue);
      expect(isFatalPlaybackError('temporary network read error'), isFalse);
    });

    test('Android never hot-swaps vo or hwdec on the running player', () {
      for (final renderer in <String>['gpu', 'gpu-next', 'mediacodec_embed']) {
        final properties = buildRendererSwitchProperties(
          renderer: renderer,
          hwdecMode: 'no',
          android: true,
        );
        expect(properties, isEmpty, reason: renderer);
      }
    });

    test('renderer switches outside Android only apply scaling properties', () {
      final properties = buildRendererSwitchProperties(
        renderer: 'gpu',
        hwdecMode: 'auto-safe',
        android: false,
      );

      expect(properties, isNot(contains('vo')));
      expect(properties, isNot(contains('hwdec')));
      expect(properties['scale'], 'bilinear');

      final highQuality = buildRendererSwitchProperties(
        renderer: 'gpu-next',
        hwdecMode: 'auto',
        android: false,
      );
      expect(highQuality['scale'], 'ewa_lanczossharp');
      expect(highQuality, isNot(contains('vo')));
      expect(highQuality, isNot(contains('hwdec')));
    });
  });
}
