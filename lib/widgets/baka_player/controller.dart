import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:baka/models/playback_state.dart';
import 'package:baka/models/subtitle_config.dart';
import 'package:baka/services/playback/anime4k.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:baka/utils/duration_utils.dart';

const String mediacodecEmbedRenderer = 'mediacodec_embed';

class PlaybackController {
  PlaybackController();

  static const videoFitTypes = <({BoxFit fit, String description})>[
    (fit: BoxFit.contain, description: '画面'),
    (fit: BoxFit.cover, description: '覆盖'),
    (fit: BoxFit.fill, description: '填充'),
    (fit: BoxFit.fitHeight, description: '高度适应'),
    (fit: BoxFit.fitWidth, description: '宽度适应'),
  ];

  static const _timelineIntervalMs = 250;
  static const _skipCancelVisibleDuration = Duration(seconds: 5);
  static const _reverseTickInterval = Duration(milliseconds: 100);
  static const _longPressPixelsPerRate = 32.0;
  static const _maxLongPressRate = 5.0;

  Player? _player;

  final core = ValueNotifier<PlaybackCoreState>(const PlaybackCoreState());
  final timeline = ValueNotifier<PlaybackTimelineState>(
    const PlaybackTimelineState(),
  );
  final overlay = ValueNotifier<PlayerOverlayState>(const PlayerOverlayState());
  final toastRevision = ValueNotifier<int>(0);
  final preferences = ValueNotifier<PlaybackPreferences>(
    const PlaybackPreferences(),
  );
  final mediaInfo = ValueNotifier<PlaybackMediaInfo>(const PlaybackMediaInfo());
  final enhancement = ValueNotifier<VideoEnhancementState>(
    const VideoEnhancementState(),
  );
  final videoController = ValueNotifier<VideoController?>(null);

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Duration> _seekEvents =
      StreamController<Duration>.broadcast();

  Timer? _hideControlsTimer;
  Timer? _skipCancelHideTimer;
  Timer? _jumpPromptTimer;
  Timer? _reversePlaybackTimer;

  Future<void>? _initializeFuture;
  Future<void>? _disposeFuture;
  Future<void> _settingsWrites = Future<void>.value();
  PlaybackPreferences _persistedPreferences = const PlaybackPreferences();
  DanmakuController? _danmakuController;

  double _lastPlaybackRate = 1.0;
  double _longPressStartRate = 1.0;
  double _reversePlaybackRate = 0.0;
  bool _playingBeforeLongPress = false;
  bool _reverseSeekInFlight = false;
  int _lastTimelineBucket = -1;
  bool _disposed = false;
  bool _roomConnected = false;
  bool _roomCanControl = true;
  bool _roomRateLocked = false;
  bool _eofReached = false;
  String? _lastOpenUri;
  Map<String, String>? _lastOpenHeaders;

  String? get currentMediaUri =>
      _player?.state.playlist.medias.firstOrNull?.uri;
  List<SubtitleTrack> get subtitleTracks =>
      _player?.state.tracks.subtitle ?? const <SubtitleTrack>[];
  SubtitleTrack get currentSubtitleTrack =>
      _player?.state.track.subtitle ?? SubtitleTrack.no();
  DanmakuController get danmakuController =>
      _danmakuController ??
      (throw StateError('Danmaku controller is not attached'));
  Stream<void> get completed => _completed.stream;
  Stream<Duration> get seekEvents => _seekEvents.stream;

  Future<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    final stored = PlaybackSettingsService.loadAll();
    var loaded = stored;
    if (Platform.isAndroid &&
        loaded.videoRenderer == mediacodecEmbedRenderer &&
        loaded.videoEnhancementMode != VideoEnhancementMode.off) {
      loaded = loaded.copyWith(videoEnhancementMode: VideoEnhancementMode.off);
      await PlaybackSettingsService.saveChanges(stored, loaded);
    }
    if (_disposed) return;
    _persistedPreferences = loaded;
    if (preferences.value == const PlaybackPreferences()) {
      preferences.value = loaded;
    }
    overlay.value = overlay.value.copyWith(
      showDanmaku: !preferences.value.defaultDanmakuOff,
    );

    _createPlayer(preferences.value.videoRenderer);
  }

  void _createPlayer(String renderer) {
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 8 * 1024 * 1024,
        title: 'BAKA Player',
      ),
    );
    _player = player;

    final embedded = Platform.isAndroid && renderer == mediacodecEmbedRenderer;
    videoController.value = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        vo: embedded ? mediacodecEmbedRenderer : null,
        hwdec: embedded ? 'mediacodec' : null,
      ),
    );
    _subscriptions.addAll([
      player.stream.playing.listen(_onPlayingChanged),
      player.stream.position.listen(_onPositionChanged),
      player.stream.duration.listen(_onDurationChanged),
      player.stream.buffer.listen(_onBufferedChanged),
      player.stream.buffering.listen(_onBufferingChanged),
      player.stream.error.listen(_onError),
      player.stream.completed.listen((completed) {
        _eofReached = completed;
        if (!_disposed && completed) _completed.add(null);
      }),
      player.stream.tracks.listen(_onTracksChanged),
    ]);
  }

  Future<void> open(
    String uri, {
    bool autoplay = true,
    Map<String, String>? httpHeaders,
    Duration? start,
  }) async {
    if (_disposed) return;
    _lastOpenUri = uri;
    _lastOpenHeaders = httpHeaders;
    try {
      _resetPlaybackState();
      await initialize();
      final player = _player;
      if (_disposed || player == null) return;
      if (currentMediaUri != null) await player.stop();
      await _configurePlayer(preferences.value.defaultPlaybackSpeed);
      await player.open(
        Media(
          uri,
          httpHeaders: httpHeaders ?? const <String, String>{},
          start: start,
        ),
        play: autoplay,
      );
      await _reapplyHwdec();
      if (!_disposed) core.value = core.value.copyWith(loading: false);
    } catch (error) {
      final safeError = sanitizePlaybackError(error);
      if (!_disposed) {
        core.value = core.value.copyWith(
          loading: false,
          buffering: false,
          failed: true,
          errorMessage: safeError,
        );
      }
      throw Exception(safeError);
    }
  }

  Future<void> _setNativeProperty(String name, String value) async {
    final platform = _player?.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty(name, value);
      } catch (e) {
        debugPrint('setNativeProperty $name failed: $e');
      }
    }
  }

  Future<void> _reapplyHwdec() async {
    await _setNativeProperty(
      'hwdec',
      effectiveHwdec(
        preferences.value.hwdecMode,
        preferences.value.videoRenderer,
      ),
    );
  }

  void attachDanmaku(DanmakuController controller) {
    _danmakuController = controller;
    controller.playbackRate = core.value.playbackRate;
    controller.syncTime(timeline.value.position);
    _syncDanmakuActivity();
  }

  void _syncDanmakuActivity() {
    final controller = _danmakuController;
    if (controller == null) return;
    final state = core.value;
    if (state.playing && !state.buffering && !state.failed) {
      controller.resume();
    } else {
      controller.pause();
    }
  }

  void detachDanmaku() {
    _danmakuController?.pause();
    _danmakuController = null;
  }

  void _onPlayingChanged(bool playing) {
    if (_disposed) return;
    final current = core.value;
    final loading = playing ? false : current.loading;
    final buffering = playing ? false : current.buffering;
    final failed = playing ? false : current.failed;
    final errorMessage = playing ? '' : current.errorMessage;
    if (current.playing == playing &&
        current.loading == loading &&
        current.buffering == buffering &&
        current.failed == failed &&
        current.errorMessage == errorMessage) {
      return;
    }
    core.value = current.copyWith(
      playing: playing,
      loading: loading,
      buffering: buffering,
      failed: failed,
      errorMessage: errorMessage,
    );
    _syncDanmakuActivity();
  }

  void _onPositionChanged(Duration position) {
    if (_disposed) return;
    if (position > Duration.zero) {
      final coreState = core.value;
      if (coreState.loading ||
          coreState.buffering ||
          coreState.failed ||
          coreState.errorMessage.isNotEmpty) {
        core.value = coreState.copyWith(
          loading: false,
          buffering: false,
          failed: false,
          errorMessage: '',
        );
        _syncDanmakuActivity();
      }
    }
    final milliseconds = position.inMilliseconds;
    final bucket = milliseconds ~/ _timelineIntervalMs;
    if (_lastTimelineBucket == bucket &&
        milliseconds >= timeline.value.position.inMilliseconds) {
      return;
    }
    _lastTimelineBucket = bucket;

    _danmakuController?.syncTime(position);
    final current = timeline.value;
    timeline.value = current.copyWith(
      position: position,
      previewPosition: current.seeking ? current.previewPosition : position,
    );
    _updateSkipState(position);
  }

  void _onDurationChanged(Duration duration) {
    if (_disposed ||
        duration == Duration.zero ||
        duration == timeline.value.duration) {
      return;
    }
    timeline.value = timeline.value.copyWith(duration: duration);
  }

  void _onBufferedChanged(Duration buffered) {
    if (_disposed || buffered == timeline.value.buffered) return;
    timeline.value = timeline.value.copyWith(buffered: buffered);
  }

  void _onTracksChanged(Tracks tracks) {
    if (_disposed) return;
    final hasTracks = tracks.subtitle.any(
      (track) => track.id != 'auto' && track.id != 'no',
    );
    if (hasTracks == core.value.hasSubtitleTracks) return;
    core.value = core.value.copyWith(hasSubtitleTracks: hasTracks);
  }

  void _onBufferingChanged(bool buffering) {
    if (_disposed || core.value.buffering == buffering) return;
    core.value = core.value.copyWith(buffering: buffering);
    _syncDanmakuActivity();
  }

  void _onError(String error) {
    if (_disposed) return;
    final safeError = sanitizePlaybackError(error);
    AppLogger.instance.warning('Playback error: $safeError', tag: 'Playback');
    if ((_player?.state.playing ?? false) && !isFatalPlaybackError(safeError)) {
      return;
    }
    _setPlaybackFailed(safeError);
  }

  void _setPlaybackFailed(String error) {
    if (_disposed) return;
    core.value = core.value.copyWith(
      loading: false,
      buffering: false,
      failed: true,
      errorMessage: error,
    );
    unawaited(_player?.pause());
    _syncDanmakuActivity();
  }

  Future<void> play({bool remote = false}) async {
    if (_disposed || (!_roomCanControl && _roomConnected && !remote)) return;
    await _player?.play();
  }

  Future<void> pause({bool remote = false}) async {
    if (_disposed || (!_roomCanControl && _roomConnected && !remote)) return;
    await _player?.pause();
    _danmakuController?.pause();
  }

  Future<void> stop() async {
    if (_disposed) return;
    await _player?.stop();
    _danmakuController?.pause();
  }

  void togglePlayback() {
    if (_roomConnected && !_roomCanControl) return;
    if (core.value.playing) {
      unawaited(pause());
    } else {
      unawaited(play());
    }
  }

  Future<void> seek(
    Duration target, {
    bool fromSlider = false,
    bool remote = false,
  }) async {
    if (_disposed || (!_roomCanControl && _roomConnected && !remote)) return;
    if (overlay.value.skipState == SkipState.waiting) {
      _setSkipState(SkipState.idle);
    }
    final resumeAfterSeek = _eofReached;
    await _performSeek(target, updatePreview: !fromSlider);
    if (resumeAfterSeek) {
      _eofReached = false;
      await play();
    }
    if (!_seekEvents.isClosed) _seekEvents.add(target);
  }

  Future<void> _performSeek(
    Duration target, {
    bool updatePreview = true,
  }) async {
    final clamped = target.clamp(Duration.zero, timeline.value.duration);
    final current = timeline.value;
    timeline.value = current.copyWith(
      position: clamped,
      previewPosition: updatePreview ? clamped : current.previewPosition,
    );
    _lastTimelineBucket = clamped.inMilliseconds ~/ _timelineIntervalMs;
    try {
      await _player?.seek(clamped);
      _danmakuController?.syncTime(clamped);
    } catch (error) {
      debugPrint('播放跳转失败: $error');
    }
  }

  Future<void> setRate(double rate, {bool roomCorrection = false}) async {
    if (_disposed || (_roomRateLocked && !roomCorrection)) return;
    final normalized = rate > 0 ? rate : 1.0;
    if (core.value.playbackRate == normalized &&
        (_player == null || _player!.state.rate == normalized)) {
      return;
    }
    core.value = core.value.copyWith(playbackRate: normalized);
    _danmakuController?.playbackRate = normalized;
    await _player?.setRate(normalized);
  }

  void setDoubleSpeed(bool enabled) {
    if (_disposed ||
        _roomRateLocked ||
        overlay.value.controlsLocked ||
        overlay.value.doubleSpeed == enabled) {
      return;
    }
    if (enabled) {
      _lastPlaybackRate = core.value.playbackRate;
      _longPressStartRate = preferences.value.longPressSpeed.clamp(
        0.0,
        _maxLongPressRate,
      );
      _playingBeforeLongPress = core.value.playing;
      overlay.value = overlay.value.copyWith(
        doubleSpeed: true,
        longPressRate: _longPressStartRate,
      );
      _notifyToastChanged();
      _applyLongPressRate(_longPressStartRate);
      return;
    }

    _stopReversePlayback();
    overlay.value = overlay.value.copyWith(doubleSpeed: false);
    _notifyToastChanged();
    _restorePlaybackAfterLongPress();
  }

  void updateDoubleSpeedOffset(double horizontalOffset) {
    if (_disposed || _roomRateLocked || !overlay.value.doubleSpeed) return;
    final rate =
        (_longPressStartRate + horizontalOffset / _longPressPixelsPerRate)
            .clamp(-_maxLongPressRate, _maxLongPressRate)
            .toDouble();
    final steppedRate = (rate * 10).round() / 10;
    if (overlay.value.longPressRate == steppedRate) return;
    overlay.value = overlay.value.copyWith(longPressRate: steppedRate);
    _notifyToastChanged();
    _applyLongPressRate(steppedRate);
  }

  Future<void> configureWatchParty({
    required bool connected,
    required bool canControl,
  }) async {
    _roomConnected = connected;
    _roomCanControl = canControl;
    _roomRateLocked = connected;
    if (connected && core.value.playbackRate != 1.0) {
      await setRate(1.0, roomCorrection: true);
    }
  }

  Future<void> _applyLongPressRate(double rate) async {
    if (_disposed || !overlay.value.doubleSpeed) return;
    if (rate > 0) {
      _stopReversePlayback();
      await setRate(rate);
      if (_playingBeforeLongPress &&
          overlay.value.doubleSpeed &&
          !core.value.playing) {
        await play();
      }
      return;
    }

    _stopReversePlayback();
    if (core.value.playing) await pause();
    if (rate < 0 && !_disposed && overlay.value.doubleSpeed) {
      _reversePlaybackRate = rate.abs();
      _reversePlaybackTimer = Timer.periodic(
        _reverseTickInterval,
        (_) => unawaited(_reversePlaybackTick()),
      );
    }
  }

  Future<void> _reversePlaybackTick() async {
    if (_reverseSeekInFlight ||
        _disposed ||
        !overlay.value.doubleSpeed ||
        overlay.value.longPressRate >= 0) {
      return;
    }
    _reverseSeekInFlight = true;
    try {
      final rewind = Duration(
        milliseconds:
            (_reverseTickInterval.inMilliseconds * _reversePlaybackRate)
                .round(),
      );
      await _performSeek(timeline.value.position - rewind);
    } finally {
      _reverseSeekInFlight = false;
    }
  }

  void _stopReversePlayback() {
    _reversePlaybackTimer?.cancel();
    _reversePlaybackTimer = null;
    _reversePlaybackRate = 0.0;
  }

  Future<void> _restorePlaybackAfterLongPress() async {
    await setRate(_lastPlaybackRate);
    if (_playingBeforeLongPress) {
      if (!core.value.playing) await play();
    } else if (core.value.playing) {
      await pause();
    }
  }

  void beginSeekPreview() {
    if (timeline.value.seeking) return;
    timeline.value = timeline.value.copyWith(seeking: true);
    _notifyToastChanged();
  }

  void updateSeekPreview(Duration value) {
    if (timeline.value.previewPosition == value) return;
    timeline.value = timeline.value.copyWith(previewPosition: value);
    _notifyToastChanged();
  }

  void endSeekPreview() {
    if (!timeline.value.seeking) return;
    timeline.value = timeline.value.copyWith(seeking: false);
    _notifyToastChanged();
    setControlsVisible(true);
  }

  void _notifyToastChanged() {
    toastRevision.value = toastRevision.value + 1;
  }

  void setControlsVisible(bool visible) {
    if (_disposed) return;
    if (overlay.value.controlsLocked && visible) return;
    if (overlay.value.controlsVisible != visible) {
      overlay.value = overlay.value.copyWith(controlsVisible: visible);
    }
    _hideControlsTimer?.cancel();
    if (visible) {
      _hideControlsTimer = Timer(const Duration(seconds: 3), () {
        if (_disposed || timeline.value.seeking) return;
        overlay.value = overlay.value.copyWith(controlsVisible: false);
      });
    }
  }

  void toggleControls() => setControlsVisible(!overlay.value.controlsVisible);

  void setControlsLocked(bool locked) {
    if (_disposed || overlay.value.controlsLocked == locked) return;
    overlay.value = overlay.value.copyWith(
      controlsLocked: locked,
      controlsVisible: locked ? false : true,
    );
    if (locked) {
      _hideControlsTimer?.cancel();
    } else {
      setControlsVisible(true);
    }
  }

  void setVolume(double value) {
    final next = value.clamp(0.0, 1.0);
    if (overlay.value.volume == next) return;
    overlay.value = overlay.value.copyWith(volume: next);
  }

  void setBrightness(double value) {
    final next = value.clamp(0.0, 1.0);
    if (overlay.value.brightness == next) return;
    overlay.value = overlay.value.copyWith(brightness: next);
  }

  void setDanmakuVisible(bool visible) {
    if (overlay.value.showDanmaku == visible) return;
    overlay.value = overlay.value.copyWith(showDanmaku: visible);
  }

  void setDanmakuInputVisible(bool visible) {
    if (overlay.value.showDanmakuInput == visible) return;
    overlay.value = overlay.value.copyWith(showDanmakuInput: visible);
    if (visible) setControlsVisible(false);
  }

  void showJumpToPositionPrompt(Duration position) {
    if (!preferences.value.rememberLastPosition || position.inSeconds <= 0) {
      return;
    }
    overlay.value = overlay.value.copyWith(
      showJumpPrompt: true,
      jumpPosition: position,
      jumpPromptText: '继续播放${position.label()}？',
    );
    _jumpPromptTimer?.cancel();
    _jumpPromptTimer = Timer(const Duration(seconds: 15), hideJumpPrompt);
  }

  void hideJumpPrompt() {
    if (!overlay.value.showJumpPrompt) return;
    overlay.value = overlay.value.copyWith(
      showJumpPrompt: false,
      jumpPosition: Duration.zero,
      jumpPromptText: '',
    );
    _jumpPromptTimer?.cancel();
  }

  void performJumpToPosition() {
    final target = overlay.value.jumpPosition;
    if (target > Duration.zero) unawaited(seek(target));
    hideJumpPrompt();
  }

  void _updateSkipState(Duration position) {
    final settings = preferences.value;
    final current = overlay.value;
    if (!settings.enableSkipOpEd) {
      if (current.skipState == SkipState.waiting) {
        _setSkipState(SkipState.idle);
      }
      return;
    }
    final seconds = position.inSeconds;
    final canSkip =
        seconds > 0 &&
        timeline.value.duration.inSeconds >
            settings.skipOpWaitTime + settings.skipOpDuration;
    if (!canSkip || current.showJumpPrompt) return;

    if (current.skipState == SkipState.idle &&
        seconds < settings.skipOpWaitTime) {
      _setSkipState(SkipState.waiting);
      return;
    }
    if (current.skipState != SkipState.waiting) return;
    if (seconds < settings.skipOpWaitTime) return;

    _showSkipCancelPrompt();
    unawaited(
      _performSeek(position + Duration(seconds: settings.skipOpDuration)),
    );
  }

  void _setSkipState(SkipState state) {
    if (overlay.value.skipState == state) return;
    overlay.value = overlay.value.copyWith(skipState: state);
  }

  void userActionSkip() {
    _showSkipCancelPrompt();
    unawaited(
      _performSeek(
        timeline.value.position +
            Duration(seconds: preferences.value.skipOpDuration),
      ),
    );
  }

  void userActionCancelSkip() {
    _skipCancelHideTimer?.cancel();
    _setSkipState(SkipState.idle);
  }

  void cancelSkipOpEd() {
    final wasShowing = overlay.value.skipState == SkipState.showingCancel;
    _skipCancelHideTimer?.cancel();
    _setSkipState(SkipState.idle);
    if (!wasShowing) return;
    final position = timeline.value.position;
    final target =
        (position - Duration(seconds: preferences.value.skipOpDuration)).clamp(
          Duration.zero,
          position,
        );
    unawaited(_performSeek(target));
  }

  void _showSkipCancelPrompt() {
    _setSkipState(SkipState.showingCancel);
    _skipCancelHideTimer?.cancel();
    _skipCancelHideTimer = Timer(_skipCancelVisibleDuration, () {
      if (_disposed || overlay.value.skipState != SkipState.showingCancel) {
        return;
      }
      _setSkipState(SkipState.idle);
    });
  }

  void setMediaInfo(PlaybackMediaInfo info) {
    mediaInfo.value = info;
  }

  Future<void> updatePreferences(
    PlaybackPreferences next, {
    bool persist = true,
  }) async {
    if (_disposed) return;
    final previous = preferences.value;
    final hwdec = PlaybackSettingsService.normalizeHwdecMode(next.hwdecMode);
    if (hwdec != next.hwdecMode) next = next.copyWith(hwdecMode: hwdec);
    if (Platform.isAndroid) {
      final rendererChanged = previous.videoRenderer != next.videoRenderer;
      final enhancementChanged =
          previous.videoEnhancementMode != next.videoEnhancementMode;
      if (rendererChanged &&
          next.videoRenderer == mediacodecEmbedRenderer &&
          next.videoEnhancementMode != VideoEnhancementMode.off) {
        next = next.copyWith(videoEnhancementMode: VideoEnhancementMode.off);
      } else if (enhancementChanged &&
          next.videoEnhancementMode != VideoEnhancementMode.off &&
          next.videoRenderer == mediacodecEmbedRenderer) {
        next = next.copyWith(videoRenderer: 'gpu');
      }
    }
    if (previous == next) return;
    preferences.value = next;
    if (previous.longPressSpeed != next.longPressSpeed) {
      _notifyToastChanged();
    }

    if (previous.videoEnhancementMode != next.videoEnhancementMode) {
      await _syncVideoEnhancement();
    }
    if (previous.subtitleConfig != next.subtitleConfig) {
      await _syncSubtitleConfig();
    }
    if (previous.showSubtitle != next.showSubtitle) {
      await _setNativeProperty(
        'sub-visibility',
        next.showSubtitle ? 'yes' : 'no',
      );
    }
    if (previous.hwdecMode != next.hwdecMode) {
      await _setNativeProperty(
        'hwdec',
        effectiveHwdec(next.hwdecMode, next.videoRenderer),
      );
    }
    if (previous.videoRenderer != next.videoRenderer) {
      if (Platform.isAndroid) {
        await _rebuildForRenderer(next.videoRenderer);
      } else {
        await _syncProperties(
          buildRendererSwitchProperties(
            renderer: next.videoRenderer,
            hwdecMode: next.hwdecMode,
          ),
        );
      }
    }
    if (persist) {
      _settingsWrites = _settingsWrites.then((_) async {
        final persisted = _persistedPreferences;
        await PlaybackSettingsService.saveChanges(persisted, next);
        _persistedPreferences = next;
      });
      await _settingsWrites;
    }
    if (previous.filterHlsAds != next.filterHlsAds) {
      await onHlsAdFilterChanged?.call(next.filterHlsAds);
    }
  }

  /// 清单处理属于播放页面；切换去广告时由页面重新准备当前媒体。
  Future<void> Function(bool enabled)? onHlsAdFilterChanged;

  Future<void> setVideoFit(BoxFit fit, String description) => updatePreferences(
    preferences.value.copyWith(videoFit: fit, videoFitDescription: description),
    persist: false,
  );

  Future<bool> toggleVideoEnhancement() async {
    final current = preferences.value;
    final enabling = current.videoEnhancementMode == VideoEnhancementMode.off;
    final mode = enabling
        ? current.lastVideoEnhancementMode
        : VideoEnhancementMode.off;
    await updatePreferences(
      current.copyWith(
        videoEnhancementMode: mode,
        lastVideoEnhancementMode: enabling
            ? mode
            : current.videoEnhancementMode,
      ),
    );
    return enabling;
  }

  Future<void> setVideoEnhancementMode(VideoEnhancementMode mode) async {
    final current = preferences.value;
    if (current.videoEnhancementMode == mode) return;
    await updatePreferences(
      current.copyWith(
        videoEnhancementMode: mode,
        lastVideoEnhancementMode: mode == VideoEnhancementMode.off
            ? current.lastVideoEnhancementMode
            : mode,
      ),
    );
  }

  Future<void> updateSubtitleConfig(
    SubtitleConfig config, {
    bool persist = true,
  }) => updatePreferences(
    preferences.value.copyWith(subtitleConfig: config),
    persist: persist,
  );

  Future<void> toggleSubtitle() => updatePreferences(
    preferences.value.copyWith(showSubtitle: !preferences.value.showSubtitle),
  );

  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    await _player?.setSubtitleTrack(track);
  }

  Future<PlaybackTechnicalInfo> loadTechnicalInfo() async {
    try {
      await initialize();
    } catch (_) {}
    final player = _player;
    final state = player?.state;
    final properties =
        (player != null && state != null && state.duration > Duration.zero)
        ? await _readNativeProperties(player)
        : const <String, String>{};
    final video = state != null ? _activeVideoTrack(state) : null;
    final audio = state != null ? _activeAudioTrack(state) : null;
    final params = state?.videoParams;
    final audioParams = state?.audioParams;
    final outputRect = videoController.value?.rect.value;
    final settings = preferences.value;
    final actual = enhancement.value;

    return PlaybackTechnicalInfo(
      width: params?.w ?? state?.width ?? video?.w,
      height: params?.h ?? state?.height ?? video?.h,
      framesPerSecond:
          _parseDouble(properties['estimated-vf-fps']) ??
          _parseDouble(properties['container-fps']) ??
          video?.fps,
      videoBitrate: _parseInt(properties['video-bitrate']) ?? video?.bitrate,
      videoCodec: _firstValue([
        properties['video-codec-name'],
        video?.codec,
        properties['video-codec'],
      ]),
      videoDecoder: _firstValue([video?.decoder, properties['video-codec']]),
      hardwareDecoder: properties['hwdec-current'],
      videoOutput: properties['current-vo'],
      graphicsApi: properties['gpu-api'],
      graphicsContext: properties['current-gpu-context'],
      pixelFormat: _firstValue([params?.pixelformat, params?.hwPixelformat]),
      colorSpace: _joinedValues([
        params?.primaries,
        params?.gamma,
        params?.colormatrix,
      ]),
      containerFormat: properties['file-format'],
      audioBitrate:
          _parseInt(properties['audio-bitrate']) ??
          state?.audioBitrate?.round() ??
          audio?.bitrate,
      audioSampleRate: audioParams?.sampleRate ?? audio?.samplerate,
      audioChannels: audioParams?.channelCount ?? audio?.channelscount,
      audioCodec: _firstValue([
        properties['audio-codec-name'],
        audio?.codec,
        properties['audio-codec'],
      ]),
      audioDecoder: _firstValue([audio?.decoder, properties['audio-codec']]),
      audioFormat: audioParams?.format,
      audioChannelLayout: _firstValue([
        audioParams?.hrChannels,
        audioParams?.channels,
        audio?.channels,
      ]),
      outputWidth: outputRect?.width.round(),
      outputHeight: outputRect?.height.round(),
      frameDropCount: _parseInt(properties['frame-drop-count']) ?? 0,
      delayedFrameCount: _parseInt(properties['vo-delayed-frame-count']) ?? 0,
      rendererProfile: settings.videoRenderer,
      hardwareDecodeMode: settings.hwdecMode,
      requestedEnhancementMode: actual.requestedMode,
      appliedEnhancementPipeline: actual.appliedPipeline,
      enhancementFallbackReason: actual.fallbackReason,
    );
  }

  Future<void> resetPreferences() {
    const defaults = PlaybackPreferences();
    overlay.value = overlay.value.copyWith(showDanmaku: true);
    return updatePreferences(defaults);
  }

  Future<void> _configurePlayer(double rate) async {
    await _syncProperties(
      buildPlayerProperties(
        hwdecMode: preferences.value.hwdecMode,
        videoRenderer: preferences.value.videoRenderer,
        videoEnhancementEnabled:
            preferences.value.videoEnhancementMode != VideoEnhancementMode.off,
        lowMemoryMode: PlaybackSettingsService.getLowMemoryMode(),
        mediaUri: _lastOpenUri,
      ),
    );
    await _syncVideoEnhancement();
    await _syncSubtitleConfig();
    await _setNativeProperty(
      'sub-visibility',
      preferences.value.showSubtitle ? 'yes' : 'no',
    );
    await setRate(rate);
  }

  Future<void> _syncProperties(Map<String, String> properties) async {
    for (final entry in properties.entries) {
      await _setNativeProperty(entry.key, entry.value);
    }
  }

  Future<void> _rebuildForRenderer(String renderer) async {
    final player = _player;
    if (player == null) return;
    final wasPlaying = player.state.playing;
    final position = player.state.position;
    final mediaUri = currentMediaUri;
    final subtitleTrack = currentSubtitleTrack;
    final rate = core.value.playbackRate;

    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    videoController.value = null;
    await player.dispose();
    _player = null;
    if (_disposed) return;
    _createPlayer(renderer);
    final newPlayer = _player!;
    _resetPlaybackState();
    await _configurePlayer(rate);

    if (mediaUri != null) {
      await newPlayer.open(
        Media(mediaUri, httpHeaders: _lastOpenHeaders ?? const {}),
        play: wasPlaying,
      );
      if (_disposed) return;
      await _reapplyHwdec();
      if (position > Duration.zero) await newPlayer.seek(position);
      if (subtitleTrack.id != 'auto' && subtitleTrack.id != 'no') {
        try {
          await newPlayer.setSubtitleTrack(subtitleTrack);
        } catch (_) {}
      }
    }
  }

  Future<void> _syncVideoEnhancement() async {
    final mode = preferences.value.videoEnhancementMode;
    final pipeline = selectEnhancementPipeline(mode);
    if (Platform.isAndroid &&
        preferences.value.videoRenderer == mediacodecEmbedRenderer &&
        pipeline != VideoEnhancementPipeline.off) {
      await _setNativeProperty('glsl-shaders', '');
      if (_disposed) return;
      enhancement.value = enhancement.value.copyWith(
        requestedMode: mode,
        appliedPipeline: VideoEnhancementPipeline.off,
        fallbackReason: 'mediacodec_embed 直接输出不经过 GPU 着色器',
      );
      return;
    }

    final framebuffer = buildVideoEnhancementFramebufferProperties(
      enabled: pipeline != VideoEnhancementPipeline.off,
    );
    if (pipeline == VideoEnhancementPipeline.off) {
      await _setNativeProperty('glsl-shaders', '');
    }
    await _syncProperties(framebuffer);
    if (pipeline != VideoEnhancementPipeline.off) {
      await _setNativeProperty(
        'glsl-shaders',
        await Anime4K.shaderPath(pipeline),
      );
    }
    if (_disposed) return;
    enhancement.value = enhancement.value.copyWith(
      requestedMode: mode,
      appliedPipeline: pipeline,
      clearFallbackReason: true,
    );
  }

  Future<void> _syncSubtitleConfig() => _syncProperties(
    buildSubtitleProperties(preferences.value.subtitleConfig),
  );

  void _resetPlaybackState() {
    _stopReversePlayback();
    _skipCancelHideTimer?.cancel();
    _jumpPromptTimer?.cancel();
    enhancement.value = VideoEnhancementState(
      requestedMode: preferences.value.videoEnhancementMode,
    );
    core.value = core.value.copyWith(
      loading: true,
      buffering: true,
      failed: false,
      errorMessage: '',
    );
    timeline.value = const PlaybackTimelineState();
    overlay.value = overlay.value.copyWith(
      doubleSpeed: false,
      skipState: SkipState.idle,
      showJumpPrompt: false,
      jumpPosition: Duration.zero,
      jumpPromptText: '',
    );
    _notifyToastChanged();
    _lastTimelineBucket = -1;
    _eofReached = false;
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _hideControlsTimer?.cancel();
    _skipCancelHideTimer?.cancel();
    _jumpPromptTimer?.cancel();
    _reversePlaybackTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _danmakuController?.pause();
    _danmakuController = null;
    await _settingsWrites;
    final player = _player;
    _player = null;
    videoController.value = null;
    if (player != null) {
      try {
        await player.pause();
      } catch (_) {}
      await player.dispose();
    }
    await _completed.close();
    await _seekEvents.close();
    core.dispose();
    timeline.dispose();
    overlay.dispose();
    toastRevision.dispose();
    preferences.dispose();
    mediaInfo.dispose();
    enhancement.dispose();
    videoController.dispose();
  }
}

// ---------------- MPV 配置与诊断辅助工具 ---------------- //

const playerProperties = <String, String>{
  'volume-max': '100',
  'hwdec': 'auto',
  'hwdec-codecs': 'all',
  'cache': 'auto',
  'cache-secs': '12',
  'demuxer-max-bytes': '16777216',
  'demuxer-max-back-bytes': '4194304',
  'demuxer-hysteresis-secs': '3',
  'network-timeout': '30',
  'tls-verify': 'no',
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
};

const localDemuxerLavfOptions =
    'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
    'protocol_whitelist=[file,http,https,tcp,udp,tls,data,crypto,ftp,rtp,rtsp,rtmp,srt]';

const networkDemuxerLavfOptions =
    'reconnect=1,multiple_requests=1,retry_open=3,hls_wrap=0,hls_allow_cache=1,'
    'fflags=+igndts+ignidx,tls_verify=0';

const lowMemoryPlayerProperties = <String, String>{
  'cache-secs': '5',
  'demuxer-max-bytes': '8388608',
  'demuxer-max-back-bytes': '2097152',
  'demuxer-hysteresis-secs': '2',
};

Map<String, String> buildPlayerProperties({
  String hwdecMode = 'auto',
  String videoRenderer = 'gpu',
  bool videoEnhancementEnabled = false,
  bool lowMemoryMode = false,
  bool? android,
  String? mediaUri,
}) {
  final isNetwork =
      mediaUri != null &&
      (mediaUri.startsWith('http://') || mediaUri.startsWith('https://'));
  return <String, String>{
    ...playerProperties,
    if (lowMemoryMode) ...lowMemoryPlayerProperties,
    'hwdec': effectiveHwdec(hwdecMode, videoRenderer, android: android),
    ...buildVideoRendererProperties(
      videoRenderer,
      android: android,
      videoEnhancementEnabled: videoEnhancementEnabled,
    ),
    'demuxer-lavf-o': isNetwork
        ? networkDemuxerLavfOptions
        : localDemuxerLavfOptions,
  };
}

String effectiveHwdec(String hwdecMode, String videoRenderer, {bool? android}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (!isAndroid) return hwdecMode;
  if (videoRenderer == mediacodecEmbedRenderer) return 'mediacodec';
  return hwdecMode == 'auto' ? 'auto-safe' : hwdecMode;
}

bool isFatalPlaybackError(String error) {
  final message = error.toLowerCase();
  return message.contains('could not open codec') ||
      message.contains('failed to open codec');
}

Map<String, String> buildRendererSwitchProperties({
  required String renderer,
  required String hwdecMode,
  bool? android,
}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (isAndroid) return const <String, String>{};
  return buildVideoRendererProperties(renderer, android: false);
}

Map<String, String> buildVideoRendererProperties(
  String renderer, {
  bool? android,
  bool videoEnhancementEnabled = false,
}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (isAndroid) {
    return <String, String>{
      'gpu-context': 'android',
      'profile': 'fast',
      'fbo-format': videoEnhancementEnabled ? 'rgba16f' : 'rgba8',
      'deband': 'no',
      'interpolation': 'no',
      'scale': 'bilinear',
      'cscale': 'bilinear',
      'dscale': 'bilinear',
      'correct-downscaling': 'no',
      'linear-downscaling': 'no',
      'sigmoid-upscaling': 'no',
    };
  }

  if (renderer == 'gpu-next') {
    return const <String, String>{
      'scale': 'ewa_lanczossharp',
      'cscale': 'ewa_lanczossharp',
      'dscale': 'mitchell',
      'correct-downscaling': 'yes',
      'linear-downscaling': 'yes',
      'sigmoid-upscaling': 'yes',
    };
  }
  return const <String, String>{
    'scale': 'bilinear',
    'cscale': 'bilinear',
    'dscale': 'bilinear',
    'correct-downscaling': 'no',
    'linear-downscaling': 'no',
    'sigmoid-upscaling': 'no',
  };
}

Map<String, String> buildVideoEnhancementFramebufferProperties({
  required bool enabled,
  bool? android,
}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (!isAndroid) return const <String, String>{};
  return <String, String>{'fbo-format': enabled ? 'rgba16f' : 'rgba8'};
}

String sanitizePlaybackError(Object error) {
  var message = error.toString();
  message = message.replaceAllMapped(
    RegExp(r'(https?:\/\/)([^\/\s?#@]+@)', caseSensitive: false),
    (match) => match.group(1)!,
  );
  message = message.replaceAll(
    RegExp(r'Authorization:\s*Basic\s+[A-Za-z0-9+/=]+', caseSensitive: false),
    'Authorization: Basic ***',
  );
  message = message.replaceAllMapped(
    RegExp(
      r'([?&](?:password|passwd|token|access_token|auth|authorization)=)[^&\s]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}***',
  );
  message = message.replaceAll(
    RegExp(r'[A-Za-z]:\\Users\\[^\\]+', caseSensitive: false),
    r'C:\Users\***',
  );
  message = message.replaceAll(
    RegExp(r'/(?:Users|home)/[^/]+', caseSensitive: false),
    '/Users/***',
  );
  return message;
}

Map<String, String> buildSubtitleProperties(SubtitleConfig config) {
  final subPos = config.position.round().clamp(0, 150);
  final subFontSize = config.fontSize.round().clamp(10, 100);

  return {
    'sub-pos': '$subPos',
    'sub-font-size': '$subFontSize',
    'sub-color': colorToMpv(
      config.fontColor.withValues(alpha: config.opacity * config.fontColor.a),
    ),
    'sub-border-size': config.borderWidth.toStringAsFixed(1),
    'sub-border-color': colorToMpv(config.borderColor),
    'sub-back-color': colorToMpv(config.backgroundColor),
    'sub-bold': config.bold ? 'yes' : 'no',
    'sub-visibility': 'no',
    if (config.fontFamily.isNotEmpty) 'sub-font': config.fontFamily,
    'sub-ass-override': 'force',
  };
}

String colorToMpv(Color color) {
  String byte(double value) {
    return (value * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
  }

  return '#${byte(color.a)}${byte(color.r)}${byte(color.g)}${byte(color.b)}';
}

const _technicalPropertyNames = <String>[
  'current-vo',
  'gpu-api',
  'current-gpu-context',
  'hwdec-current',
  'video-codec',
  'video-codec-name',
  'file-format',
  'estimated-vf-fps',
  'container-fps',
  'video-bitrate',
  'audio-codec',
  'audio-codec-name',
  'audio-bitrate',
  'frame-drop-count',
  'vo-delayed-frame-count',
];

Future<Map<String, String>> _readNativeProperties(Player player) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return const <String, String>{};

  final result = <String, String>{};
  for (final name in _technicalPropertyNames) {
    try {
      final value = (await platform.getProperty(name)).trim();
      if (value.isNotEmpty && value.toLowerCase() != 'n/a') {
        result[name] = value;
      }
    } catch (_) {}
  }
  return result;
}

VideoTrack? _activeVideoTrack(PlayerState state) {
  final selected = state.track.video;
  if (selected.id != 'auto' && selected.id != 'no') {
    for (final track in state.tracks.video) {
      if (track.id == selected.id) return track;
    }
    return selected;
  }
  VideoTrack? fallback;
  for (final track in state.tracks.video) {
    if (track.id == 'auto' || track.id == 'no') continue;
    if (track.isDefault == true) return track;
    fallback ??= track;
  }
  return fallback;
}

AudioTrack? _activeAudioTrack(PlayerState state) {
  final selected = state.track.audio;
  if (selected.id != 'auto' && selected.id != 'no') {
    for (final track in state.tracks.audio) {
      if (track.id == selected.id) return track;
    }
    return selected;
  }
  AudioTrack? fallback;
  for (final track in state.tracks.audio) {
    if (track.id == 'auto' || track.id == 'no') continue;
    if (track.isDefault == true) return track;
    fallback ??= track;
  }
  return fallback;
}

String? _firstValue(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

String? _joinedValues(Iterable<String?> values) {
  final result = <String>[];
  for (final value in values) {
    final normalized = value?.trim();
    if (normalized != null &&
        normalized.isNotEmpty &&
        !result.contains(normalized)) {
      result.add(normalized);
    }
  }
  return result.isEmpty ? null : result.join(' / ');
}

double? _parseDouble(String? value) =>
    value == null ? null : double.tryParse(value);

int? _parseInt(String? value) => _parseDouble(value)?.round();
