import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/models/subtitle_config.dart';

/// 播放器设置持久化服务
class PlaybackSettingsService {
  PlaybackSettingsService._();

  static const _defaultDanmakuOffKey = 'player_defaultDanmakuOff';
  static const _defaultPlaybackSpeedKey = 'player_defaultPlaybackSpeed';
  static const _clearCacheOnExitKey = 'app_clearCacheOnExit';
  static const _lowMemoryModeKey = 'app_lowMemoryMode';
  static const _rememberLastPositionKey = 'player_rememberLastPosition';
  static const _autoFullscreenKey = 'player_autoFullscreen';
  static const _enableSkipOpEdKey = 'player_enableSkipOpEd';
  static const _longPressSpeedKey = 'player_longPressSpeed';
  static const _showNextEpisodeButtonKey = 'player_showNextEpisodeButton';
  static const _enableDoubleTapKey = 'player_enableDoubleTap';
  static const _doubleTapActionKey = 'player_doubleTapAction';
  static const _doubleTapSeekDurationKey = 'player_doubleTapSeekDuration';
  static const _showSystemTimeKey = 'player_showSystemTime';
  static const _skipOpWaitTimeKey = 'player_skipOpWaitTime';
  static const _skipOpDurationKey = 'player_skipOpDuration';
  static const _videoEnhancementModeKey = 'player_videoEnhancementMode';
  static const _lastVideoEnhancementModeKey = 'player_lastVideoEnhancementMode';
  static const _showSubtitleKey = 'player_showSubtitle';
  static const _hwdecModeKey = 'player_hwdecMode';
  static const _videoRendererKey = 'player_videoRenderer';

  static const hwdecModeLabels = <String, String>{
    'auto': '自动',
    'auto-safe': '安全模式',
    'mediacodec-copy': '硬解复制',
    'no': '软件解码',
  };

  static const videoRendererLabels = <String, String>{
    'gpu': 'gpu',
    'gpu-next': 'gpu-next',
    'mediacodec_embed': 'mediacodec_embed',
  };

  static const doubleTapActionLabels = <String, String>{
    'seek': '快进快退',
    'play_pause': '播放暂停',
  };

  static final hwdecModeOptions = hwdecModeLabels.keys.toList(growable: false);
  static final videoRendererOptions = videoRendererLabels.keys.toList(
    growable: false,
  );

  static List<String> get hwdecModeOptionsForPlatform {
    return Instances.isTV
        ? const ['auto-safe', 'mediacodec-copy', 'no']
        : hwdecModeOptions;
  }

  static Map<String, String> get hwdecModeLabelsForPlatform {
    return Instances.isTV
        ? const {
            'auto-safe': '安全模式',
            'mediacodec-copy': '硬解复制',
            'no': '软件解码',
          }
        : hwdecModeLabels;
  }

  static List<String> get videoRendererOptionsForPlatform {
    return Platform.isAndroid
        ? const ['gpu', 'mediacodec_embed']
        : const ['gpu', 'gpu-next'];
  }

  static Map<String, String> get videoRendererLabelsForPlatform {
    return Platform.isAndroid
        ? const {'gpu': 'gpu', 'mediacodec_embed': 'mediacodec_embed'}
        : const {'gpu': 'gpu', 'gpu-next': 'gpu-next'};
  }

  static const defaultPlaybackSpeed = 1.0;
  static const playbackSpeedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    2.5,
    3.0,
    4.0,
  ];

  static final _speedLabelTrim = RegExp(r'\.?0+$');

  static String normalizeHwdecMode(String? mode) {
    final effective = Instances.isTV && mode == 'auto' ? null : mode;
    if (effective != null && hwdecModeLabels.containsKey(effective)) {
      return effective;
    }
    return Instances.isTV ? 'mediacodec-copy' : 'auto';
  }

  static String normalizeVideoRenderer(String? renderer, {bool? android}) {
    final isAndroid = android ?? Platform.isAndroid;
    if (renderer == null || renderer == 'auto' || renderer == 'compatibility') {
      return 'gpu';
    }
    if (renderer == 'quality') {
      return isAndroid ? 'gpu' : 'gpu-next';
    }
    if (isAndroid && renderer == 'gpu-next') return 'gpu';
    return videoRendererLabels.containsKey(renderer) ? renderer : 'gpu';
  }

  static double normalizePlaybackSpeed(double? speed) =>
      (speed != null && playbackSpeedOptions.contains(speed))
          ? speed
          : defaultPlaybackSpeed;

  static String formatPlaybackSpeed(double speed) =>
      '${speed.toStringAsFixed(2).replaceFirst(_speedLabelTrim, '')}x';

  static SharedPreferences get _prefs => Instances.sp;

  static bool getClearCacheOnExit() =>
      _prefs.getBool(_clearCacheOnExitKey) ?? false;

  static Future<void> setClearCacheOnExit(bool value) =>
      _prefs.setBool(_clearCacheOnExitKey, value);

  static bool getLowMemoryMode() => _prefs.getBool(_lowMemoryModeKey) ?? false;

  static const lowMemoryImageCount = 80;
  static const lowMemoryImageBytes = 32 * 1024 * 1024;
  static int? _normalImageCount;
  static int? _normalImageBytes;

  static void applyLowMemoryMode(bool enabled) {
    final cache = PaintingBinding.instance.imageCache;
    _normalImageCount ??= cache.maximumSize;
    _normalImageBytes ??= cache.maximumSizeBytes;
    cache.maximumSize = enabled ? lowMemoryImageCount : _normalImageCount!;
    cache.maximumSizeBytes = enabled ? lowMemoryImageBytes : _normalImageBytes!;
    if (enabled) cache.clearLiveImages();
  }

  static Future<void> setLowMemoryMode(bool value) async {
    await _prefs.setBool(_lowMemoryModeKey, value);
    applyLowMemoryMode(value);
  }

  static PlaybackPreferences loadAll() {
    final sp = _prefs;
    VideoEnhancementMode enhancementMode;
    VideoEnhancementMode lastEnhancementMode;

    if (sp.containsKey(_videoEnhancementModeKey)) {
      enhancementMode = VideoEnhancementMode.fromStorage(
        sp.getString(_videoEnhancementModeKey),
      );
      final storedLastMode = VideoEnhancementMode.fromStorage(
        sp.getString(_lastVideoEnhancementModeKey),
      );
      lastEnhancementMode = storedLastMode != VideoEnhancementMode.off
          ? storedLastMode
          : (enhancementMode != VideoEnhancementMode.off
              ? enhancementMode
              : VideoEnhancementMode.medium);
    } else {
      final legacyLevel = VideoEnhancementMode.fromStorage(
        sp.getString('player_anime4KLevel'),
      );
      final effectiveLegacyLevel = legacyLevel != VideoEnhancementMode.off
          ? legacyLevel
          : VideoEnhancementMode.medium;
      final legacyEnabled = sp.getBool('player_enableAnime4K') ?? false;
      enhancementMode =
          legacyEnabled ? effectiveLegacyLevel : VideoEnhancementMode.off;
      lastEnhancementMode = effectiveLegacyLevel;
    }

    return PlaybackPreferences(
      rememberLastPosition: sp.getBool(_rememberLastPositionKey) ?? true,
      autoFullscreen: sp.getBool(_autoFullscreenKey) ?? false,
      enableSkipOpEd: sp.getBool(_enableSkipOpEdKey) ?? false,
      defaultDanmakuOff: sp.getBool(_defaultDanmakuOffKey) ?? false,
      defaultPlaybackSpeed: normalizePlaybackSpeed(
        sp.getDouble(_defaultPlaybackSpeedKey),
      ),
      longPressSpeed: sp.getDouble(_longPressSpeedKey) ?? 2.0,
      showNextEpisodeButton: sp.getBool(_showNextEpisodeButtonKey) ?? true,
      enableDoubleTap: sp.getBool(_enableDoubleTapKey) ?? true,
      doubleTapAction: sp.getString(_doubleTapActionKey) ?? 'play_pause',
      doubleTapSeekDuration: sp.getInt(_doubleTapSeekDurationKey) ?? 10,
      showSystemTime: sp.getBool(_showSystemTimeKey) ?? false,
      skipOpWaitTime: (sp.getInt(_skipOpWaitTimeKey) ?? 105).clamp(30, 300),
      skipOpDuration: (sp.getInt(_skipOpDurationKey) ?? 85).clamp(30, 300),
      videoEnhancementMode: enhancementMode,
      lastVideoEnhancementMode: lastEnhancementMode,
      showSubtitle: sp.getBool(_showSubtitleKey) ?? true,
      subtitleConfig: SubtitleConfig.load(),
      hwdecMode: normalizeHwdecMode(sp.getString(_hwdecModeKey)),
      videoRenderer: normalizeVideoRenderer(sp.getString(_videoRendererKey)),
    );
  }

  static Future<void> saveChanges(
    PlaybackPreferences previous,
    PlaybackPreferences next,
  ) {
    if (identical(previous, next) || previous == next) {
      return Future.value();
    }

    final sp = _prefs;
    final writes = <Future<void>>[];

    void write(String key, Object before, Object after) {
      if (before == after) return;
      if (after is bool) {
        writes.add(sp.setBool(key, after));
      } else if (after is int) {
        writes.add(sp.setInt(key, after));
      } else if (after is double) {
        writes.add(sp.setDouble(key, after));
      } else if (after is String) {
        writes.add(sp.setString(key, after));
      }
    }

    write(_rememberLastPositionKey, previous.rememberLastPosition, next.rememberLastPosition);
    write(_autoFullscreenKey, previous.autoFullscreen, next.autoFullscreen);
    write(_enableSkipOpEdKey, previous.enableSkipOpEd, next.enableSkipOpEd);
    write(_defaultDanmakuOffKey, previous.defaultDanmakuOff, next.defaultDanmakuOff);
    write(_defaultPlaybackSpeedKey, previous.defaultPlaybackSpeed, next.defaultPlaybackSpeed);
    write(_longPressSpeedKey, previous.longPressSpeed, next.longPressSpeed);
    write(_showNextEpisodeButtonKey, previous.showNextEpisodeButton, next.showNextEpisodeButton);
    write(_enableDoubleTapKey, previous.enableDoubleTap, next.enableDoubleTap);
    write(_doubleTapActionKey, previous.doubleTapAction, next.doubleTapAction);
    write(_doubleTapSeekDurationKey, previous.doubleTapSeekDuration, next.doubleTapSeekDuration);
    write(_showSystemTimeKey, previous.showSystemTime, next.showSystemTime);
    write(_skipOpWaitTimeKey, previous.skipOpWaitTime, next.skipOpWaitTime);
    write(_skipOpDurationKey, previous.skipOpDuration, next.skipOpDuration);
    write(_videoEnhancementModeKey, previous.videoEnhancementMode.storageValue, next.videoEnhancementMode.storageValue);
    write(_lastVideoEnhancementModeKey, previous.lastVideoEnhancementMode.storageValue, next.lastVideoEnhancementMode.storageValue);
    write(_showSubtitleKey, previous.showSubtitle, next.showSubtitle);
    write(_hwdecModeKey, previous.hwdecMode, next.hwdecMode);
    write(_videoRendererKey, previous.videoRenderer, next.videoRenderer);

    if (previous.subtitleConfig != next.subtitleConfig) {
      writes.add(next.subtitleConfig.save());
    }

    return writes.isEmpty ? Future.value() : Future.wait(writes);
  }
}
