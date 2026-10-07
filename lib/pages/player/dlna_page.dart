import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart' hide ContextExtensionss;

/// DLNA 投屏下一集 URL 解析回调
typedef DlnaEpisodeUrlResolver = Future<String?> Function(int episodeIndex);

/// 投屏切集回调（通知 PlayerPage 同步更新 UI 状态）
typedef DlnaEpisodeChangedCallback = void Function(int episodeIndex);

/// 投屏控制器（持久化，不随 UI 关闭而销毁）
class DlnaController extends GetxController {
  DlnaController({
    required this.initialDatasource,
    required this.animeTitle,
    required this.videoList,
    required this.initialEpisodeIndex,
  });

  String initialDatasource;
  String animeTitle;
  List<PlaybackEpisode> videoList;
  int initialEpisodeIndex;
  DlnaEpisodeUrlResolver? urlResolver;
  DlnaEpisodeChangedCallback? onEpisodeChanged;

  final deviceList = <String, DLNADevice>{}.obs;
  DLNADevice? selectedDevice;

  final isSearching = true.obs;
  final isConnected = false.obs;
  final autoNextEnabled = true.obs;
  final currentEpisodeIndex = 0.obs;
  final transportState = 'UNKNOWN'.obs;
  final isLoadingNext = false.obs;

  final currentPosition = Duration.zero.obs;
  final totalDuration = Duration.zero.obs;
  final isSeeking = false.obs;

  final DLNAManager searcher = DLNAManager();
  Timer? _stopSearchTimer;
  Timer? _pollTimer;
  StreamSubscription? _deviceSub;
  bool _hasStartedPlaying = false;
  bool _isPolling = false;

  static final _stateRegex = RegExp(
    r'<CurrentTransportState>([^<]+)</CurrentTransportState>',
  );
  static final _relTimeRegex = RegExp(r'<RelTime>([^<]+)</RelTime>');
  static final _trackDurRegex = RegExp(
    r'<TrackDuration>([^<]+)</TrackDuration>',
  );

  bool get hasNextEpisode => currentEpisodeIndex.value + 1 < videoList.length;
  bool get hasPrevEpisode => currentEpisodeIndex.value > 0;

  @override
  void onInit() {
    super.onInit();
    currentEpisodeIndex.value = initialEpisodeIndex;
    searcher.stop();
    startSearch();
  }

  @override
  void onClose() {
    _deviceSub?.cancel();
    _stopSearchTimer?.cancel();
    _pollTimer?.cancel();
    searcher.stop();
    super.onClose();
  }

  void startSearch() async {
    _deviceSub?.cancel();
    _stopSearchTimer?.cancel();

    isSearching.value = true;
    isConnected.value = false;
    deviceList.clear();

    _stopSearchTimer = Timer(const Duration(seconds: 20), () {
      isSearching.value = false;
      searcher.stop();
    });

    final m = await searcher.start();
    _deviceSub = m.devices.stream.listen((devices) {
      deviceList.assignAll(devices);
    });
  }

  Future<void> selectDevice(DLNADevice dev) async {
    if (selectedDevice != null) {
      _pollTimer?.cancel();
      selectedDevice!.stop();
    }

    selectedDevice = dev;
    isConnected.value = true;
    _hasStartedPlaying = false;

    await _castCurrentEpisode(initialDatasource);
  }

  Future<void> _castCurrentEpisode(String url) async {
    if (selectedDevice == null || url.isEmpty) return;
    final title = '$animeTitle P${currentEpisodeIndex.value + 1}';
    await selectedDevice!.setUrl(url, title: title);
    await selectedDevice!.play();
    _hasStartedPlaying = true;
    transportState.value = 'PLAYING';
    currentPosition.value = Duration.zero;
    totalDuration.value = Duration.zero;
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _isPolling = false;
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_isPolling) return;
      _isPolling = true;
      await _pollStatus();
      _isPolling = false;
    });
  }

  Future<void> _pollStatus() async {
    if (selectedDevice == null) return;
    try {
      final futures = await Future.wait([
        selectedDevice!.getTransportInfo(),
        selectedDevice!.position(),
      ]);

      final stateMatch = _stateRegex.firstMatch(futures[0]);
      final state = stateMatch?.group(1) ?? 'UNKNOWN';
      transportState.value = state;

      if (!isSeeking.value) {
        final posMatch = _relTimeRegex.firstMatch(futures[1]);
        if (posMatch != null) {
          final pos = _parseDuration(posMatch.group(1)!);
          if (pos != null) currentPosition.value = pos;
        }

        final durMatch = _trackDurRegex.firstMatch(futures[1]);
        if (durMatch != null) {
          final dur = _parseDuration(durMatch.group(1)!);
          if (dur != null && dur > Duration.zero) totalDuration.value = dur;
        }
      }

      if (_hasStartedPlaying && state == 'STOPPED') {
        _hasStartedPlaying = false;
        if (autoNextEnabled.value) {
          _playNextEpisode();
        }
      }
    } catch (_) {
      // 忽略轮询错误以保持连接
    }
  }

  Duration? _parseDuration(String str) {
    final parts = str.split(':');
    if (parts.length == 3) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      final s = int.tryParse(parts[2].split('.').first) ?? 0;
      return Duration(hours: h, minutes: m, seconds: s);
    }
    return null;
  }

  Future<void> seekTo(Duration position) async {
    if (selectedDevice == null) return;
    isSeeking.value = true;
    final h = position.inHours.toString().padLeft(2, '0');
    final m = (position.inMinutes % 60).toString().padLeft(2, '0');
    final s = (position.inSeconds % 60).toString().padLeft(2, '0');
    try {
      await selectedDevice!.seek('$h:$m:$s');
      currentPosition.value = position;
    } finally {
      isSeeking.value = false;
    }
  }

  Future<void> _playNextEpisode() async {
    final nextIndex = currentEpisodeIndex.value + 1;
    if (nextIndex >= videoList.length) {
      transportState.value = 'COMPLETED_ALL';
      _pollTimer?.cancel();
      return;
    }
    await playEpisodeAt(nextIndex);
  }

  Future<void> playEpisodeAt(int index) async {
    if (index < 0 || index >= videoList.length || selectedDevice == null) {
      return;
    }

    _pollTimer?.cancel();
    _hasStartedPlaying = false;
    isLoadingNext.value = true;

    try {
      String? url;
      if (urlResolver != null) {
        url = await urlResolver!(index);
      }
      if (url == null || url.isEmpty) {
        transportState.value = 'ERROR';
        return;
      }

      currentEpisodeIndex.value = index;
      onEpisodeChanged?.call(index);
      await _castCurrentEpisode(url);
    } catch (_) {
      transportState.value = 'ERROR';
    } finally {
      isLoadingNext.value = false;
    }
  }

  Future<void> togglePlayPause() async {
    if (selectedDevice == null) return;
    if (transportState.value == 'PLAYING') {
      await selectedDevice!.pause();
      transportState.value = 'PAUSED_PLAYBACK';
    } else if (transportState.value == 'PAUSED_PLAYBACK') {
      await selectedDevice!.play();
      transportState.value = 'PLAYING';
    }
  }

  Future<void> stopCast() async {
    _pollTimer?.cancel();
    _hasStartedPlaying = false;
    await selectedDevice?.stop();
    isConnected.value = false;
    transportState.value = 'STOPPED';
    currentPosition.value = Duration.zero;
    totalDuration.value = Duration.zero;
  }
}

/// 投屏面板（Bottom Sheet）
class DlnaCastPanel extends StatelessWidget {
  final String datasource;
  final String animeTitle;
  final List<PlaybackEpisode> videoList;
  final int currentEpisodeIndex;
  final DlnaEpisodeUrlResolver? urlResolver;
  final DlnaEpisodeChangedCallback? onEpisodeChanged;

  const DlnaCastPanel({
    required this.datasource,
    required this.animeTitle,
    required this.videoList,
    required this.currentEpisodeIndex,
    this.urlResolver,
    this.onEpisodeChanged,
    super.key,
  });

  static const _tag = 'dlna_cast';

  @override
  Widget build(BuildContext context) {
    final c = Get.isRegistered<DlnaController>(tag: _tag)
        ? Get.find<DlnaController>(tag: _tag)
        : Get.put(
            DlnaController(
              initialDatasource: datasource,
              animeTitle: animeTitle,
              videoList: videoList,
              initialEpisodeIndex: currentEpisodeIndex,
            ),
            tag: _tag,
            permanent: true,
          );

    // 每次构建更新最新的瞬态回调和列表，避免旧闭包捕获
    c.urlResolver = urlResolver;
    c.onEpisodeChanged = onEpisodeChanged;
    c.videoList = videoList;
    c.animeTitle = animeTitle;

    final portrait = isBottomPlayerPanel(context);
    final theme = playerPanelTheme(
      Theme.of(context),
      bottom: true,
      compact: isCompactPlayerPanel(context) && !portrait,
    );
    final media = MediaQuery.of(context);
    final height = portrait
        ? (media.size.height - media.padding.top - media.size.width * 9 / 16)
              .clamp(0.0, media.size.height * 0.74)
        : (media.size.height - media.padding.top) * 0.9;

    return Theme(
      data: theme,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: height,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                SizedBox(
                  height: 24,
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.4,
                        ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '投屏',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: '收起投屏面板',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Obx(
                    () => c.isConnected.value
                        ? _buildCastControls(c, theme)
                        : _buildDeviceList(c, theme),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceList(DlnaController c, ThemeData theme) {
    final colors = theme.colorScheme;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    c.isSearching.value ? '正在搜索设备' : '可用设备',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.primary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '重新搜索设备',
                  onPressed: c.startSearch,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ),
        if (c.deviceList.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (c.isSearching.value)
                    const CircularProgressIndicator()
                  else
                    Icon(Icons.tv_off_rounded, size: 48, color: colors.primary),
                  const SizedBox(height: 20),
                  Text(
                    c.isSearching.value ? '寻找附近的投屏设备' : '未找到可用设备',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '请确保手机与电视连接同一网络',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (!c.isSearching.value) ...[
                    const SizedBox(height: 24),
                    FilledButton.tonalIcon(
                      onPressed: c.startSearch,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新搜索'),
                    ),
                  ],
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            sliver: SliverList.builder(
              itemCount: c.deviceList.length,
              itemBuilder: (context, index) {
                final dev = c.deviceList.values.elementAt(index);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(24),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      minTileHeight: 76,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      leading: Icon(Icons.cast_rounded, color: colors.primary),
                      title: Text(
                        dev.info.friendlyName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        HapticFeedback.mediumImpact();
                        c.selectDevice(dev);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildCastControls(DlnaController c, ThemeData theme) {
    final colors = theme.colorScheme;
    final groupShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: colors.surfaceContainerHigh,
            shape: groupShape,
            child: ListTile(
              minTileHeight: 76,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: const Icon(Icons.cast_connected_rounded),
              ),
              title: Text(
                c.selectedDevice?.info.friendlyName ?? '投屏设备',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '已连接',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Text(
              '正在播放',
              style: theme.textTheme.titleSmall?.copyWith(
                color: colors.primary,
              ),
            ),
          ),
          Material(
            color: colors.surfaceContainerHigh,
            shape: groupShape,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Obx(() {
                    final index = c.currentEpisodeIndex.value;
                    final episode = index >= 0 && index < c.videoList.length
                        ? c.videoList[index].title
                        : '第 ${index + 1} 集';
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${c.animeTitle} · $episode',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          c.isLoadingNext.value
                              ? '正在切换剧集…'
                              : switch (c.transportState.value) {
                                  'ERROR' => '切集失败，请重试',
                                  'PAUSED_PLAYBACK' => '已暂停',
                                  'COMPLETED_ALL' => '已播放完全部剧集',
                                  _ => '当前剧集',
                                },
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    );
                  }),
                  _buildSeekBar(c, theme),
                  const SizedBox(height: 8),
                  Obx(() {
                    final busy = c.isLoadingNext.value;
                    final playing = c.transportState.value == 'PLAYING';
                    final canToggle =
                        playing || c.transportState.value == 'PAUSED_PLAYBACK';
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(
                          tooltip: '上一集',
                          iconSize: 28,
                          style: IconButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          onPressed: !busy && c.hasPrevEpisode
                              ? () {
                                  HapticFeedback.lightImpact();
                                  c.playEpisodeAt(
                                    c.currentEpisodeIndex.value - 1,
                                  );
                                }
                              : null,
                          icon: const Icon(Icons.skip_previous_rounded),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filled(
                          tooltip: playing ? '暂停投屏' : '继续投屏',
                          iconSize: 40,
                          style: IconButton.styleFrom(
                            minimumSize: const Size(72, 72),
                            backgroundColor: colors.primary,
                            foregroundColor: colors.onPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                          ),
                          onPressed: !busy && canToggle
                              ? () {
                                  HapticFeedback.mediumImpact();
                                  c.togglePlayPause();
                                }
                              : null,
                          icon: busy
                              ? const SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                  ),
                                )
                              : Icon(
                                  playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.filledTonal(
                          tooltip: '下一集',
                          iconSize: 28,
                          style: IconButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          onPressed: !busy && c.hasNextEpisode
                              ? () {
                                  HapticFeedback.lightImpact();
                                  c.playEpisodeAt(
                                    c.currentEpisodeIndex.value + 1,
                                  );
                                }
                              : null,
                          icon: const Icon(Icons.skip_next_rounded),
                        ),
                      ],
                    );
                  }),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
            child: Text(
              '播放设置',
              style: theme.textTheme.titleSmall?.copyWith(
                color: colors.primary,
              ),
            ),
          ),
          Material(
            color: colors.surfaceContainerHigh,
            shape: groupShape,
            clipBehavior: Clip.antiAlias,
            child: Obx(
              () => SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text('自动播放下一集', style: theme.textTheme.bodyLarge),
                subtitle: Text(
                  c.hasNextEpisode
                      ? '剩余 ${c.videoList.length - c.currentEpisodeIndex.value - 1} 集'
                      : '已是最后一集',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                value: c.autoNextEnabled.value,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  c.autoNextEnabled.value = v;
                },
              ),
            ),
          ),
          const SizedBox(height: 18),
          Material(
            color: colors.surfaceContainerHigh,
            shape: groupShape,
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              minTileHeight: 56,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: Icon(Icons.tv_off_rounded, color: colors.primary),
              title: Text(
                '断开投屏',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colors.primary,
                ),
              ),
              onTap: c.stopCast,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeekBar(DlnaController c, ThemeData theme) {
    return Obx(() {
      final pos = c.currentPosition.value;
      final dur = c.totalDuration.value;
      final seekable = dur > Duration.zero && !c.isLoadingNext.value;
      final progress = dur.inMilliseconds > 0
          ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
          : 0.0;
      final timeStyle = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      return Column(
        children: [
          Slider(
            value: progress,
            semanticFormatterCallback: (_) =>
                '${pos.toTimeString()} / ${dur.toTimeString()}',
            onChangeStart: seekable ? (_) => c.isSeeking.value = true : null,
            onChanged: seekable
                ? (v) {
                    c.currentPosition.value = Duration(
                      milliseconds: (v * dur.inMilliseconds).round(),
                    );
                  }
                : null,
            onChangeEnd: seekable
                ? (v) {
                    c.seekTo(
                      Duration(milliseconds: (v * dur.inMilliseconds).round()),
                    );
                  }
                : null,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(pos.toTimeString(), style: timeStyle),
              Text(dur.toTimeString(), style: timeStyle),
            ],
          ),
        ],
      );
    });
  }
}
