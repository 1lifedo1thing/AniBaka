import 'dart:io';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/anime4k.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('preferences and migration', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
    });

    tearDown(() {
      Instances.isTV = false;
    });

    test('persists only keys changed between preference snapshots', () async {
      const previous = PlaybackPreferences();
      final next = previous.copyWith(autoFullscreen: true, longPressSpeed: 2.5);
      await PlaybackSettingsService.saveChanges(previous, next);

      expect(Instances.sp.getKeys(), {
        'player_autoFullscreen',
        'player_longPressSpeed',
      });
      expect(Instances.sp.getBool('player_autoFullscreen'), isTrue);
      expect(Instances.sp.getDouble('player_longPressSpeed'), 2.5);

      await Instances.sp.clear();
      await PlaybackSettingsService.saveChanges(previous, previous);
      expect(Instances.sp.getKeys(), isEmpty);
    });

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

    test('normalizes hwdec modes including the Android TV default', () {
      expect(PlaybackSettingsService.normalizeHwdecMode('auto'), 'auto');
      expect(
        PlaybackSettingsService.normalizeHwdecMode('auto-safe'),
        'auto-safe',
      );
      expect(
        PlaybackSettingsService.normalizeHwdecMode('mediacodec-copy'),
        'mediacodec-copy',
      );
      expect(PlaybackSettingsService.normalizeHwdecMode('no'), 'no');
      expect(PlaybackSettingsService.normalizeHwdecMode('bogus'), 'auto');
      expect(PlaybackSettingsService.normalizeHwdecMode(null), 'auto');

      Instances.isTV = true;
      // 未设置或遗留的 auto 一律落到 mediacodec-copy。
      expect(
        PlaybackSettingsService.normalizeHwdecMode(null),
        'mediacodec-copy',
      );
      expect(
        PlaybackSettingsService.normalizeHwdecMode('auto'),
        'mediacodec-copy',
      );
      expect(
        PlaybackSettingsService.normalizeHwdecMode('bogus'),
        'mediacodec-copy',
      );
      // 用户显式选择的模式保持不变。
      expect(
        PlaybackSettingsService.normalizeHwdecMode('auto-safe'),
        'auto-safe',
      );
      expect(PlaybackSettingsService.normalizeHwdecMode('no'), 'no');
      expect(
        PlaybackSettingsService.normalizeHwdecMode('mediacodec-copy'),
        'mediacodec-copy',
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

    test(
      'persists new enhancement mode without rewriting legacy keys',
      () async {
        const previous = PlaybackPreferences();
        final next = previous.copyWith(
          videoEnhancementMode: VideoEnhancementMode.medium,
          lastVideoEnhancementMode: VideoEnhancementMode.medium,
        );

        await PlaybackSettingsService.saveChanges(previous, next);

        expect(Instances.sp.getString('player_videoEnhancementMode'), 'medium');
        expect(Instances.sp.containsKey('player_enableAnime4K'), isFalse);
        expect(Instances.sp.containsKey('player_anime4KLevel'), isFalse);
      },
    );

    test(
      'persists subtitle configuration with the preference snapshot',
      () async {
        const previous = PlaybackPreferences();
        final next = previous.copyWith(
          subtitleConfig: previous.subtitleConfig.copyWith(fontSize: 32),
        );

        await PlaybackSettingsService.saveChanges(previous, next);

        expect(Instances.sp.getKeys(), {'subtitle_settings'});
        expect(
          Instances.sp.getString('subtitle_settings'),
          contains('"fontSize":32'),
        );
      },
    );
  });

  group('renderer configuration', () {
    test('gpu-next changes only libmpv rendering properties on desktop', () {
      final properties = buildVideoRendererProperties(
        'gpu-next',
        android: false,
      );

      expect(properties['scale'], 'ewa_lanczossharp');
      expect(properties['correct-downscaling'], 'yes');
      expect(properties, isNot(contains('vo')));
    });

    test('low memory mode reduces the bounded demuxer cache', () {
      final normal = buildPlayerProperties();
      final lowMemory = buildPlayerProperties(lowMemoryMode: true);

      expect(normal['demuxer-max-bytes'], '16777216');
      expect(normal['demuxer-max-back-bytes'], '4194304');
      expect(lowMemory['demuxer-max-bytes'], '8388608');
      expect(lowMemory['demuxer-max-back-bytes'], '2097152');
      expect(lowMemory['cache-secs'], '5');
    });

    test('network streams use reconnect and timestamp recovery options', () {
      final properties = buildPlayerProperties(
        mediaUri: 'https://example.com/stream.m3u8',
      );
      final options = properties['demuxer-lavf-o']!;

      expect(options, contains('reconnect=1'));
      expect(options, contains('igndts'));
      expect(options, contains('ignidx'));
      expect(properties, isNot(contains('rebase-start-time')));
      expect(properties, isNot(contains('hr-seek')));
      expect(properties, isNot(contains('hr-seek-demuxer-offset')));
    });

    test('Android gpu profile pins rgba8 and disables heavy GPU features', () {
      final properties = buildPlayerProperties(
        videoRenderer: 'gpu',
        android: true,
      );

      expect(properties['gpu-context'], 'android');
      expect(properties['profile'], 'fast');
      expect(properties['fbo-format'], 'rgba8');
      expect(properties['deband'], 'no');
      expect(properties['interpolation'], 'no');
      expect(properties['scale'], 'bilinear');
      expect(properties['cscale'], 'bilinear');
      expect(properties['dscale'], 'bilinear');
      expect(properties['correct-downscaling'], 'no');
      expect(properties, isNot(contains('vo')));

      // Anime4K 在 Android 上需要带符号半浮点帧缓冲。
      expect(
        buildPlayerProperties(
          videoRenderer: 'gpu',
          videoEnhancementEnabled: true,
          android: true,
        )['fbo-format'],
        'rgba16f',
      );
      expect(
        buildVideoEnhancementFramebufferProperties(
          enabled: false,
          android: true,
        )['fbo-format'],
        'rgba8',
      );
      expect(
        buildVideoEnhancementFramebufferProperties(
          enabled: true,
          android: false,
        ),
        isEmpty,
      );

      // gpu-next 在 Android 上没有对应的 profile，回落成保守的 gpu 配置。
      final gpuNext = buildPlayerProperties(
        videoRenderer: 'gpu-next',
        android: true,
      );
      expect(gpuNext['fbo-format'], 'rgba8');
      expect(gpuNext['scale'], 'bilinear');
      expect(gpuNext, isNot(contains('vo')));
    });

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

  group('image budget', () {
    final cache = PaintingBinding.instance.imageCache;
    final normalImageCount = cache.maximumSize;
    final normalImageBytes = cache.maximumSizeBytes;

    tearDown(() {
      PlaybackSettingsService.applyLowMemoryMode(false);
    });

    test('low memory mode applies and restores the decoded image budget', () {
      PlaybackSettingsService.applyLowMemoryMode(true);

      expect(cache.maximumSize, PlaybackSettingsService.lowMemoryImageCount);
      expect(
        cache.maximumSizeBytes,
        PlaybackSettingsService.lowMemoryImageBytes,
      );

      PlaybackSettingsService.applyLowMemoryMode(false);

      expect(cache.maximumSize, normalImageCount);
      expect(cache.maximumSizeBytes, normalImageBytes);
    });
  });

  group('shader staging', () {
    test(
      'shader staging replaces stale bytes and verifies the final file',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'anibaka-shader-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final target = File(
          '${directory.path}${Platform.pathSeparator}shader.glsl',
        );
        await target.writeAsBytes([1, 2, 3]);

        final staged = await Anime4K.stageBytesForTest(
          directory,
          'shader.glsl',
          [4, 5, 6, 7],
        );

        expect(staged.path, target.path);
        expect(await staged.readAsBytes(), [4, 5, 6, 7]);
        expect(
          directory.listSync().whereType<File>().map((file) => file.path),
          [target.path],
        );
      },
    );
  });
}
