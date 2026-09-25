import 'dart:ui' as ui;
import 'package:flutter/material.dart';

Future<void> showPlayerSettingsPanel(BuildContext context, Widget child) {
  final theme = Theme.of(context);
  final colors = ColorScheme.fromSeed(
    seedColor: theme.colorScheme.primary,
    brightness: Brightness.dark,
  );
  return showDialog(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) {
      final screenWidth = MediaQuery.sizeOf(context).width;
      final width = screenWidth < 600
          ? screenWidth
          : (screenWidth * 0.55).clamp(400.0, 560.0);
      return Theme(
        data: theme.copyWith(
          iconTheme: const IconThemeData(color: Colors.white),
          iconButtonTheme: IconButtonThemeData(
            style: IconButton.styleFrom(
              foregroundColor: colors.onSecondaryContainer,
            ),
          ),
          brightness: Brightness.dark,
          colorScheme: colors,
          textTheme: theme.textTheme.apply(
            bodyColor: Colors.white,
            displayColor: Colors.white,
          ),
          sliderTheme: SliderThemeData(
            trackHeight: 16,
            trackGap: 6,
            tickMarkShape: SliderTickMarkShape.noTickMark,
            trackShape: const GappedSliderTrackShape(),
            thumbShape: const HandleThumbShape(),
            thumbSize: const WidgetStatePropertyAll(Size(4, 36)),
            activeTrackColor: colors.primary,
            inactiveTrackColor: colors.surfaceContainerHighest.withValues(
              alpha: 0.7,
            ),
            thumbColor: colors.primary,
            showValueIndicator: ShowValueIndicator.onDrag,
            padding: const EdgeInsets.symmetric(horizontal: 4),
          ),
          switchTheme: SwitchThemeData(
            thumbIcon: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? Icon(Icons.check_rounded, size: 16, color: colors.primary)
                  : null,
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor: colors.secondaryContainer.withValues(
                alpha: 0.66,
              ),
              foregroundColor: colors.onSecondaryContainer,
              shape: const StadiumBorder(),
            ),
          ),
        ),
        child: Dialog(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(width: width),
          alignment: Alignment.centerRight,
          elevation: 0,
          child: child,
        ),
      );
    },
  );
}

class PanelContainer extends StatelessWidget {
  final String title;
  final Widget child;
  const PanelContainer({required this.title, required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The empty leading space lets the scrim dissolve into the video without
        // fading the controls or creating a visible drawer edge.
        final leading = constraints.maxWidth < 400 ? 20.0 : 64.0;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: const [
                Color(0x00090E16),
                Color(0x8F090E16),
                Color(0xA1090E16),
                Color(0xB8090E16),
              ],
              stops: [0, (leading + 8) / constraints.maxWidth, 0.5, 1],
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.only(left: leading, right: 8),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(
                    color: Colors.white,
                    shadows: [Shadow(color: Color(0x99000000), blurRadius: 3)],
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton.filledTonal(
                              tooltip: '关闭设置',
                              style: IconButton.styleFrom(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer
                                    .withValues(alpha: 0.66),
                              ),
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class PanelResetButton extends StatelessWidget {
  final VoidCallback onPressed;
  const PanelResetButton({required this.onPressed, super.key});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.restart_alt_rounded, size: 20),
      label: const Text('恢复默认设置'),
    ),
  );
}

class PanelExpandToggle extends StatelessWidget {
  final bool isExpanded;
  final VoidCallback onTap;
  const PanelExpandToggle({
    required this.isExpanded,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: FilledButton.tonal(
      onPressed: onTap,
      child: Row(
        children: [
          Expanded(child: Text(isExpanded ? '收起更多设置' : '展开更多设置')),
          Icon(
            isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          ),
        ],
      ),
    ),
  );
}

class PanelSectionTitle extends StatelessWidget {
  final String title;
  const PanelSectionTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class PanelSettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const PanelSettingsGroup({required this.children, super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}

class PanelDivider extends StatelessWidget {
  const PanelDivider({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 8);
}

class PanelSliderTile extends StatelessWidget {
  final String title;
  final double value;
  final String valueLabel;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  const PanelSliderTile({
    required this.title,
    required this.value,
    required this.valueLabel,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.onChangeEnd,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: ShapeDecoration(
                  color: colors.secondaryContainer.withValues(alpha: 0.66),
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  valueLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          Semantics(
            label: title,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: valueLabel,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板里的下拉选择行，窄屏和长选项也能保持在面板内。
class PanelSelectTile extends StatelessWidget {
  final String title;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;
  const PanelSelectTile({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          flex: 2,
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: ShapeDecoration(
              color: Theme.of(
                context,
              ).colorScheme.secondaryContainer.withValues(alpha: 0.66),
              shape: const StadiumBorder(),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                dropdownColor: const Color(0xFF202833),
                borderRadius: BorderRadius.circular(20),
                icon: const Icon(
                  Icons.expand_more_rounded,
                  color: Colors.white70,
                  size: 20,
                ),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontSize: 14,
                ),
                items: [
                  for (final option in options.entries)
                    DropdownMenuItem(
                      value: option.key,
                      child: Text(
                        option.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (next) {
                  if (next != null) onChanged(next);
                },
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class PanelSwitchTile extends StatelessWidget {
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? subtitle;
  const PanelSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    super.key,
  });

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        color: Color(0xFFD4DCE5),
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    ),
  );
}
