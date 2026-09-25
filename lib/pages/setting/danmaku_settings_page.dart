import 'package:flutter/material.dart';
import 'package:baka/theme.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/widgets/danmaku/danmaku_list_sheet.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/player/settings_panel.dart';

class DanmakuSettingsPage extends StatefulWidget {
  final DanmakuController controller;
  final String? defaultTitle;
  final int? defaultEpisode;

  const DanmakuSettingsPage({
    required this.controller,
    this.defaultTitle,
    this.defaultEpisode,
    super.key,
  });

  static Future<void> show(
    BuildContext context,
    DanmakuController controller, {
    String? defaultTitle,
    int? defaultEpisode,
  }) async {
    await showPlayerSettingsPanel(
      context,
      DanmakuSettingsPage(
        controller: controller,
        defaultTitle: defaultTitle,
        defaultEpisode: defaultEpisode,
      ),
    );
  }

  @override
  State<DanmakuSettingsPage> createState() => _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends State<DanmakuSettingsPage> {
  bool _isAppearanceExpanded = false;

  final TextEditingController _wordController = TextEditingController();

  @override
  void dispose() {
    _wordController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() =>
      DanmakuController.saveSettings(widget.controller);

  void _updateOption(DanmakuOption newOpt, {bool persist = false}) {
    setState(() => widget.controller.updateOption(newOpt));
    if (persist) _saveSettings();
  }

  void _resetSettings() {
    final option = DanmakuOption(fontSize: DanmakuOption.defaultFontSize);
    setState(() {
      widget.controller.updateOption(option);
      widget.controller.blockWords.clear();
      widget.controller.blockRepeat = false;
      widget.controller.blockColor = false;
    });
    _saveSettings();
    showSnackBar('已恢复默认设置');
  }

  void _addBlockWord(String word) {
    final t = word.trim();
    if (t.isEmpty || widget.controller.blockWords.contains(t)) return;
    setState(() => widget.controller.blockWords.add(t));
    _saveSettings();
  }

  void _removeBlockWord(String word) {
    setState(() => widget.controller.blockWords.remove(word));
    _saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final option = widget.controller.option;
    final blockWords = widget.controller.blockWords;

    return PanelContainer(
      title: '弹幕设置',
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const PanelSectionTitle('弹幕匹配'),
                FilledButton.tonal(
                  onPressed: () => DanmakuListSheet.show(
                    context,
                    widget.controller,
                    defaultTitle: widget.defaultTitle,
                    defaultEpisode: widget.defaultEpisode,
                    initialShowSearch: true,
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.search_rounded),
                      SizedBox(width: 12),
                      Expanded(child: Text('搜索弹幕')),
                      Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                const PanelSectionTitle('弹幕外观'),

                PanelSettingsGroup(
                  children: [
                    PanelSliderTile(
                      title: '显示区域',
                      value: option.area,
                      valueLabel: '${(option.area * 100).round()}%',
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      onChanged: (v) => _updateOption(option.copyWith(area: v)),
                      onChangeEnd: (_) => _saveSettings(),
                    ),
                    const PanelDivider(),
                    PanelSliderTile(
                      title: '透明度',
                      value: option.opacity,
                      valueLabel: '${(option.opacity * 100).round()}%',
                      min: 0.1,
                      max: 1.0,
                      divisions: 9,
                      onChanged: (v) =>
                          _updateOption(option.copyWith(opacity: v)),
                      onChangeEnd: (_) => _saveSettings(),
                    ),
                    if (_isAppearanceExpanded) ...[
                      const PanelDivider(),
                      PanelSelectTile(
                        title: '字体',
                        value: option.fontFamily,
                        options: AppFonts.fontOptions,
                        onChanged: (fontFamily) => _updateOption(
                          option.copyWith(fontFamily: fontFamily),
                          persist: true,
                        ),
                      ),
                      const PanelDivider(),
                      PanelSliderTile(
                        title: '字体大小',
                        value: option.fontSize,
                        valueLabel: '${option.fontSize.round()}',
                        min: 12,
                        max: 36,
                        divisions: 12,
                        onChanged: (v) =>
                            _updateOption(option.copyWith(fontSize: v)),
                        onChangeEnd: (_) => _saveSettings(),
                      ),
                      const PanelDivider(),
                      PanelSliderTile(
                        title: '描边宽度',
                        value: option.strokeWidth,
                        valueLabel: option.strokeWidth.toStringAsFixed(1),
                        min: 0,
                        max: 5,
                        divisions: 10,
                        onChanged: (v) =>
                            _updateOption(option.copyWith(strokeWidth: v)),
                        onChangeEnd: (_) => _saveSettings(),
                      ),
                      const PanelDivider(),
                      PanelSliderTile(
                        title: '弹幕速度',
                        value: 20.0 - option.duration,
                        valueLabel: '${option.duration.toStringAsFixed(1)}s',
                        min: 5.0,
                        max: 15.0,
                        divisions: 10,
                        onChanged: (v) =>
                            _updateOption(option.copyWith(duration: 20.0 - v)),
                        onChangeEnd: (_) => _saveSettings(),
                      ),
                    ],
                    const PanelDivider(),
                    PanelExpandToggle(
                      isExpanded: _isAppearanceExpanded,
                      onTap: () => setState(
                        () => _isAppearanceExpanded = !_isAppearanceExpanded,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                const PanelSectionTitle('弹幕类型'),
                Row(
                  children: [
                    Expanded(
                      child: _buildTypeToggleBtn(
                        label: '滚动',
                        isActive: !option.hideScroll,
                        onTap: () => _updateOption(
                          option.copyWith(hideScroll: !option.hideScroll),
                          persist: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _buildTypeToggleBtn(
                        label: '顶部',
                        isActive: !option.hideTop,
                        onTap: () => _updateOption(
                          option.copyWith(hideTop: !option.hideTop),
                          persist: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _buildTypeToggleBtn(
                        label: '底部',
                        isActive: !option.hideBottom,
                        onTap: () => _updateOption(
                          option.copyWith(hideBottom: !option.hideBottom),
                          persist: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                const PanelSectionTitle('屏蔽管理'),
                PanelSwitchTile(
                  title: '屏蔽重复弹幕',
                  value: widget.controller.blockRepeat,
                  onChanged: (value) {
                    setState(() => widget.controller.blockRepeat = value);
                    _saveSettings();
                  },
                ),
                PanelSwitchTile(
                  title: '屏蔽彩色弹幕',
                  value: widget.controller.blockColor,
                  onChanged: (value) {
                    setState(() => widget.controller.blockColor = value);
                    _saveSettings();
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _wordController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          hintText: '输入关键词屏蔽',
                          hintStyle: const TextStyle(color: Colors.white70),
                          filled: true,
                          fillColor: theme.colorScheme.secondaryContainer
                              .withValues(alpha: 0.66),
                          border: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(28)),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                        onSubmitted: (word) {
                          _addBlockWord(word);
                          _wordController.clear();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: '添加屏蔽词',
                      onPressed: () {
                        _addBlockWord(_wordController.text);
                        _wordController.clear();
                      },
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
                if (blockWords.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final word in blockWords)
                        InputChip(
                          label: Text(word),
                          onDeleted: () => _removeBlockWord(word),
                          deleteButtonTooltipMessage: '移除屏蔽词',
                        ),
                    ],
                  ),
                ],

                const SizedBox(height: 32),

                PanelResetButton(onPressed: _resetSettings),
                const SizedBox(height: 32),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeToggleBtn({
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: isActive,
      child: FilledButton.tonal(
        onPressed: onTap,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 8),
          ),
          backgroundColor: WidgetStatePropertyAll(
            isActive
                ? colors.primary
                : colors.secondaryContainer.withValues(alpha: 0.66),
          ),
          foregroundColor: WidgetStatePropertyAll(
            isActive ? colors.onPrimary : colors.onSecondaryContainer,
          ),
          shape: WidgetStateProperty.resolveWith(
            (states) => RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                states.contains(WidgetState.pressed)
                    ? 12
                    : isActive
                    ? 28
                    : 18,
              ),
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isActive) ...[
              const Icon(Icons.check_rounded, size: 16),
              const SizedBox(width: 4),
            ],
            Flexible(child: Text(label, maxLines: 1)),
          ],
        ),
      ),
    );
  }
}
