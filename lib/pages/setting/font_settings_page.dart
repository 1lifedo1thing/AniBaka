import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/app_state.dart';
import 'package:baka/theme.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:baka/widgets/settings/settings_widgets.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

TextStyle _fontStyle(String fontName, {FontWeight? fontWeight}) =>
    AppFonts.isSystemFont(fontName)
    ? TextStyle(fontWeight: fontWeight)
    : GoogleFonts.getFont(fontName, fontWeight: fontWeight);

class FontSettingsPage extends StatefulWidget {
  const FontSettingsPage({super.key});

  @override
  State<FontSettingsPage> createState() => _FontSettingsPageState();
}

class _FontSettingsPageState extends State<FontSettingsPage> {
  final _theme = Get.find<AppState>();
  late final ValueNotifier<double> _fontScale;
  late final ValueNotifier<String> _danmakuFontFamily;

  @override
  void initState() {
    super.initState();
    _fontScale = ValueNotifier(_theme.fontScale);
    _danmakuFontFamily = ValueNotifier(DanmakuController.getSavedFontFamily());
  }

  @override
  void dispose() {
    _fontScale.dispose();
    _danmakuFontFamily.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SettingsSliverAppBar(title: '字体设置'),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 12),
                _buildPreviewCard(isDark),
                const SizedBox(height: 24),
                const SettingsSectionHeader('字体大小', bottomPadding: 4),
                const SizedBox(height: 8),
                _buildFontScaleSlider(isDark),
                const SizedBox(height: 20),
                const SettingsSectionHeader('字重', bottomPadding: 4),
                const SizedBox(height: 8),
                _buildFontWeightSelector(isDark),
                const SizedBox(height: 20),
                const SettingsSectionHeader('弹幕字体', bottomPadding: 4),
                const SizedBox(height: 8),
                _buildDanmakuFontSelector(isDark),
                const SizedBox(height: 20),
                ..._buildFontCategories(isDark),
                const SizedBox(height: 24),
                _buildHintCard(isDark),
                const SizedBox(height: 40),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDanmakuFontSelector(bool isDark) {
    return ValueListenableBuilder<String>(
      valueListenable: _danmakuFontFamily,
      builder: (context, fontFamily, _) => SettingsGroup(
        children: [
          ListTile(
            leading: const Icon(Icons.subtitles_rounded),
            title: const Text('播放器弹幕字体'),
            subtitle: Text(
              '默认 ${AppFonts.getLabelForFont(AppFonts.defaultFont)} · '
              '当前 ${AppFonts.getLabelForFont(fontFamily)}',
            ),
            trailing: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: fontFamily,
                borderRadius: BorderRadius.circular(12),
                items: [
                  for (final option in AppFonts.fontOptions.entries)
                    DropdownMenuItem(
                      value: option.key,
                      child: Text(
                        option.value,
                        style: _fontStyle(option.key).copyWith(
                          fontSize: 14,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                ],
                onChanged: (next) {
                  if (next == null || next == _danmakuFontFamily.value) return;
                  HapticFeedback.selectionClick();
                  _danmakuFontFamily.value = next;
                  DanmakuController.setFontFamily(next);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Obx(() {
        final selectedFont = _theme.fontFamily;
        final style = _fontStyle(selectedFont, fontWeight: _theme.fontWeight);
        return ValueListenableBuilder<double>(
          valueListenable: _fontScale,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: ThemeColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.preview_rounded,
                  size: 18,
                  color: ThemeColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '预览效果',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: ThemeColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  AppFonts.getLabelForFont(selectedFont),
                  style: const TextStyle(
                    fontSize: 12,
                    color: ThemeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          builder: (context, fontScale, heading) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading!,
              const SizedBox(height: 20),
              Text(
                '命运石之门',
                style: style.copyWith(
                  fontSize: 22 * fontScale,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '这一切都是命运石之门的选择',
                style: style.copyWith(
                  fontSize: 14 * fontScale,
                  height: 1.8,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'EL PSY KONGROO Steins;Gate 1.048596%',
                style: style.copyWith(
                  fontSize: 12 * fontScale,
                  letterSpacing: 1,
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildFontScaleSlider(bool isDark) {
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    'A',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _fontScale,
                      builder: (context, scale, _) => Slider(
                        value: scale,
                        min: 0.8,
                        max: 1.30,
                        divisions: 11,
                        activeColor: ThemeColors.primary,
                        inactiveColor: isDark
                            ? Colors.white12
                            : Colors.black.withValues(alpha: 0.06),
                        onChanged: (value) => _fontScale.value = value,
                        onChangeEnd: (value) {
                          if (value != _theme.fontScale) {
                            _theme.setFontScale(value);
                          }
                        },
                      ),
                    ),
                  ),
                  Text(
                    'A',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ValueListenableBuilder<double>(
                valueListenable: _fontScale,
                builder: (context, scale, _) => Text(
                  '${(scale * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 13,
                    color: ThemeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFontWeightSelector(bool isDark) {
    return SettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Obx(
            () => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < AppFonts.availableWeights.length; i++)
                  ChoiceChip(
                    label: Text(
                      AppFonts.weightLabels[i],
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: AppFonts.availableWeights[i],
                      ),
                    ),
                    selected: _theme.fontWeightIndex == i,
                    onSelected: (_) {
                      if (_theme.fontWeightIndex == i) return;
                      HapticFeedback.selectionClick();
                      _theme.setFontWeightIndex(i);
                    },
                    showCheckmark: false,
                    selectedColor: ThemeColors.primary,
                    side: BorderSide(
                      color: isDark ? Colors.white10 : Colors.black12,
                      width: 0.5,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Iterable<Widget> _buildFontCategories(bool isDark) sync* {
    const categories = {
      'system': AppFonts.systemFonts,
      'sans': AppFonts.sansFonts,
      'serif': AppFonts.serifFonts,
      'display': AppFonts.displayFonts,
    };

    for (final entry in categories.entries) {
      final catLabel = AppFonts.categoryLabels[entry.key] ?? entry.key;
      final fonts = entry.value;
      yield SettingsSectionHeader(catLabel, bottomPadding: 4);
      yield const SizedBox(height: 8);
      yield Obx(
        () => SettingsGroup(
          children: ListTile.divideTiles(
            context: context,
            tiles: [
              for (final font in fonts)
                ListTile(
                  selected: _theme.fontFamily == font['name'],
                  selectedColor: ThemeColors.primary,
                  leading: Icon(
                    _theme.fontFamily == font['name']
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                  ),
                  title: Text(font['label']!),
                  subtitle: Text(font['name']!),
                  trailing: Text(
                    font['preview']!,
                    style:
                        _fontStyle(
                          font['name']!,
                          fontWeight: FontWeight.w500,
                        ).copyWith(
                          fontSize: 16,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                  ),
                  onTap: () {
                    final name = font['name']!;
                    if (_theme.fontFamily == name) return;
                    HapticFeedback.selectionClick();
                    _theme.setFontFamily(name);
                  },
                ),
            ],
          ).toList(growable: false),
        ),
      );
      yield const SizedBox(height: 20);
    }
  }

  Widget _buildHintCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: isDark ? Colors.white24 : Colors.black26,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '字体通过 Google Fonts 在线加载，首次使用需要网络连接',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white30 : Colors.black38,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
