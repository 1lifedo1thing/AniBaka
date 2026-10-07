import 'package:baka/widgets/player/skip_segments_panel.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/models/skip_segment.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:baka/widgets/player/skip_segment_track.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:flutter/material.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';

class PlayerSettingsPage extends StatelessWidget {
  final PlaybackController controller;
  final bool _advanced;

  const PlayerSettingsPage({required this.controller, super.key})
    : _advanced = false;

  const PlayerSettingsPage._advanced({required this.controller})
    : _advanced = true;

  static Future<void> show(
    BuildContext context,
    PlaybackController controller,
  ) async {
    await controller.initialize();

    if (!context.mounted) return;
    return showPlayerSettingsPanel(
      context,
      PlayerSettingsPage(controller: controller),
    );
  }

  Future<void> _resetToDefaults() async {
    await controller.resetPreferences();
    showSnackBar('已重置为默认设置');
  }

  Future<void> _update(
    PlaybackPreferences Function(PlaybackPreferences current) change, {
    bool persist = true,
  }) {
    return controller.updatePreferences(
      change(controller.preferences.value),
      persist: persist,
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = isCompactPlayerPanel(context);
    final bottom = isBottomPlayerPanel(context);
    return ValueListenableBuilder<PlaybackPreferences>(
      valueListenable: controller.preferences,
      builder: (context, preferences, _) => PanelContainer(
        title: _advanced ? '更多播放设置' : '播放器设置',
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: playerPanelContentPadding(context),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (!_advanced) ...[
                    const PanelSectionTitle('播放体验'),
                    PanelSettingsGroup(
                      children: [
                        PanelSwitchTile(
                          title: '记住播放位置',
                          subtitle: '再次打开时提示继续播放',
                          value: preferences.rememberLastPosition,
                          onChanged: (value) => _update(
                            (current) =>
                                current.copyWith(rememberLastPosition: value),
                          ),
                        ),
                        const PanelDivider(),
                        PanelSwitchTile(
                          title: '自动全屏',
                          subtitle: '播放开始时自动进入全屏',
                          value: preferences.autoFullscreen,
                          onChanged: (value) => _update(
                            (current) =>
                                current.copyWith(autoFullscreen: value),
                          ),
                        ),
                        if (!bottom) const PanelDivider(),
                      ],
                    ),
                    SizedBox(height: compact ? 12 : 24),
                    const PanelSectionTitle('智能跳过'),
                    PanelSettingsGroup(
                      children: [
                        PanelSwitchTile(
                          title: '自动跳过片头片尾',
                          subtitle: compact
                              ? '匹配区间时跳过，第 1 集保留'
                              : '有匹配区间时自动跳过，第 1 集始终保留',
                          value: preferences.enableSkipOpEd,
                          onChanged: (value) => _update(
                            (current) =>
                                current.copyWith(enableSkipOpEd: value),
                          ),
                        ),
                        const PanelDivider(),
                        if (!bottom) _SkipSummary(controller: controller),
                        if (!bottom) SizedBox(height: compact ? 6 : 12),
                        if (bottom)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            minTileHeight: 56,
                            titleTextStyle: Theme.of(
                              context,
                            ).textTheme.bodyLarge,
                            subtitleTextStyle: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                            title: const Text('查看与校正区间'),
                            subtitle: const Text('调整片头片尾的起止时间'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () =>
                                SkipSegmentsPanel.show(context, controller),
                          )
                        else
                          FilledButton.tonal(
                            onPressed: () =>
                                SkipSegmentsPanel.show(context, controller),
                            child: const Row(
                              children: [
                                Expanded(child: Text('查看与校正区间')),
                                Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                          ),
                        if (!bottom) SizedBox(height: compact ? 6 : 12),
                        if (!bottom)
                          const Text(
                            '无匹配数据时保持正常播放',
                            style: TextStyle(
                              color: Color(0xFFD4DCE5),
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),

                    SizedBox(height: compact ? 12 : 24),
                  ],

                  const PanelSectionTitle('手势交互'),
                  PanelSettingsGroup(
                    children: [
                      if (!_advanced) ...[
                        PanelSliderTile(
                          title: '长按倍速',
                          value: preferences.longPressSpeed,
                          valueLabel: '${preferences.longPressSpeed}x',
                          min: 1.5,
                          max: 5.0,
                          divisions: 7,
                          onChanged: (value) => _update(
                            (current) => current.copyWith(
                              longPressSpeed: (value * 10).round() / 10,
                            ),
                            persist: false,
                          ),
                          onChangeEnd: (value) => _update(
                            (current) => current.copyWith(
                              longPressSpeed: (value * 10).round() / 10,
                            ),
                          ),
                        ),
                      ],
                      if (!bottom || _advanced) ...[
                        if (!_advanced) const PanelDivider(),
                        PanelSwitchTile(
                          title: '双击功能',
                          value: preferences.enableDoubleTap,
                          onChanged: (value) => _update(
                            (current) =>
                                current.copyWith(enableDoubleTap: value),
                          ),
                        ),
                        if (preferences.enableDoubleTap)
                          Column(
                            children: [
                              const PanelDivider(),
                              PanelSelectTile(
                                title: '双击动作',
                                value: preferences.doubleTapAction,
                                options: PlaybackSettingsService
                                    .doubleTapActionLabels,
                                onChanged: (value) => _update(
                                  (current) =>
                                      current.copyWith(doubleTapAction: value),
                                ),
                              ),
                              const PanelDivider(),
                              PanelSliderTile(
                                title: '快进时长',
                                value: preferences.doubleTapSeekDuration
                                    .toDouble(),
                                valueLabel:
                                    '${preferences.doubleTapSeekDuration}秒',
                                min: 5,
                                max: 60,
                                divisions: 11,
                                onChanged: (value) => _update(
                                  (current) => current.copyWith(
                                    doubleTapSeekDuration: value.round(),
                                  ),
                                  persist: false,
                                ),
                                onChangeEnd: (value) => _update(
                                  (current) => current.copyWith(
                                    doubleTapSeekDuration: value.round(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ],
                  ),

                  SizedBox(height: compact ? 16 : 32),

                  if (!bottom || _advanced) ...[
                    const PanelSectionTitle('更多播放设置'),
                    PanelSettingsGroup(
                      children: [
                        PanelSwitchTile(
                          title: '显示系统时间',
                          subtitle: '在播放器顶部显示时间',
                          value: preferences.showSystemTime,
                          onChanged: (value) => _update(
                            (current) =>
                                current.copyWith(showSystemTime: value),
                          ),
                        ),
                        const PanelDivider(),
                        PanelSwitchTile(
                          title: '显示下一集按钮',
                          subtitle: '在片尾提示中显示下一集操作',
                          value: preferences.showNextEpisodeButton,
                          onChanged: (value) => _update(
                            (current) =>
                                current.copyWith(showNextEpisodeButton: value),
                          ),
                        ),
                        const PanelDivider(),
                        PanelSwitchTile(
                          title: 'HLS 视频去广告',
                          subtitle: '自动识别并剔除 m3u8 流中插入的广告片段',
                          value: preferences.filterHlsAds,
                          onChanged: (value) => _update(
                            (current) => current.copyWith(filterHlsAds: value),
                          ),
                        ),
                        PanelSelectTile(
                          title: '硬件解码',
                          value: preferences.hwdecMode,
                          options: PlaybackSettingsService
                              .hwdecModeLabelsForPlatform,
                          onChanged: (value) => _update(
                            (current) => current.copyWith(hwdecMode: value),
                          ),
                        ),
                        const PanelDivider(),
                        PanelSelectTile(
                          title: '视频渲染器',
                          value: preferences.videoRenderer,
                          options: PlaybackSettingsService
                              .videoRendererLabelsForPlatform,
                          onChanged: (value) => _update(
                            (current) => current.copyWith(videoRenderer: value),
                          ),
                        ),
                      ],
                    ),

                    SizedBox(height: compact ? 12 : 24),

                    PanelResetButton(onPressed: _resetToDefaults),
                    SizedBox(height: compact ? 16 : 32),
                  ] else
                    PanelSettingsGroup(
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          minTileHeight: 56,
                          titleTextStyle: Theme.of(context).textTheme.bodyLarge,
                          subtitleTextStyle: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                          title: const Text('更多播放设置'),
                          subtitle: const Text('双击手势、解码与播放偏好'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => showPlayerSettingsPanel(
                            context,
                            PlayerSettingsPage._advanced(
                              controller: controller,
                            ),
                          ),
                        ),
                      ],
                    ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkipSummary extends StatelessWidget {
  const _SkipSummary({required this.controller});
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SkipData>(
    valueListenable: controller.skipData,
    builder: (context, data, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final type in ['op', 'ed'])
          Padding(
            padding: EdgeInsets.symmetric(
              vertical: isCompactPlayerPanel(context) ? 4 : 10,
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: SkipSegmentColors.forType(type),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  type == 'op' ? '片头' : '片尾',
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
                SizedBox(width: isCompactPlayerPanel(context) ? 12 : 20),
                Expanded(
                  child: Text(
                    _range(data, type),
                    style: const TextStyle(
                      color: Color(0xFFD4DCE5),
                      fontSize: 14,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Text(
          data.context?.isFirstEpisode == true
              ? '第 1 集保留片头片尾，仅标记区间'
              : '仅当前剧集与片源 · 颜色对应进度条标记',
          style: const TextStyle(color: Color(0xFFD4DCE5), fontSize: 12),
        ),
      ],
    ),
  );

  String _range(SkipData data, String type) {
    final segment = data.segments.where((s) => s.type == type).firstOrNull;
    if (segment == null) return '暂无匹配区间';
    return '${Duration(milliseconds: segment.startMs).toTimeString()} – '
        '${Duration(milliseconds: segment.endMs).toTimeString()}';
  }
}
