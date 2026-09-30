import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool isCompactPlayerPanel(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide < 600;

EdgeInsets playerPanelContentPadding(BuildContext context) =>
    isCompactPlayerPanel(context)
    ? const EdgeInsets.fromLTRB(8, 4, 8, 12)
    : const EdgeInsets.fromLTRB(16, 12, 16, 24);

Future<void> showPlayerSettingsPanel(BuildContext context, Widget child) {
  if (context.findAncestorStateOfType<_PlayerSettingsPanelState>() != null) {
    return Navigator.of(context).push<void>(_panelRoute(child));
  }

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
      final compact = isCompactPlayerPanel(context);
      final width = compact
          ? (screenWidth * (screenWidth < 600 ? 0.88 : 0.38))
                .clamp(280.0, 340.0)
                .clamp(0.0, screenWidth)
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
          visualDensity: compact ? VisualDensity.compact : theme.visualDensity,
          colorScheme: colors,
          textTheme: theme.textTheme.apply(
            bodyColor: Colors.white,
            displayColor: Colors.white,
          ),
          sliderTheme: SliderThemeData(
            trackHeight: compact ? 10 : 16,
            trackGap: compact ? 4 : 6,
            tickMarkShape: SliderTickMarkShape.noTickMark,
            trackShape: const GappedSliderTrackShape(),
            thumbShape: const HandleThumbShape(),
            thumbSize: WidgetStatePropertyAll(Size(4, compact ? 28 : 36)),
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
              minimumSize: Size(44, compact ? 40 : 48),
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
          child: _PlayerSettingsPanel(child: child),
        ),
      );
    },
  );
}

PageRoute<void> _panelRoute(Widget child) => PageRouteBuilder<void>(
  // Keep the previous page alive but offstage, so its translucent surface and
  // controls cannot show through the current page, even during a transition.
  pageBuilder: (_, _, _) => child,
  transitionDuration: Duration.zero,
  reverseTransitionDuration: Duration.zero,
);

class _PlayerSettingsPanel extends StatefulWidget {
  const _PlayerSettingsPanel({required this.child});

  final Widget child;

  @override
  State<_PlayerSettingsPanel> createState() => _PlayerSettingsPanelState();
}

class _PlayerSettingsPanelState extends State<_PlayerSettingsPanel> {
  late NavigatorState _navigator;

  void close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (_navigator.canPop()) {
          _navigator.pop();
        } else {
          close();
        }
      },
    },
    child: NavigatorPopHandler<void>(
      onPopWithResult: (_) => _navigator.pop(),
      child: Navigator(
        onGenerateInitialRoutes: (navigator, _) {
          _navigator = navigator;
          return [_panelRoute(widget.child)];
        },
      ),
    ),
  );
}

class PanelContainer extends StatelessWidget {
  final String title;
  final Widget child;
  const PanelContainer({required this.title, required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final panel = context.findAncestorStateOfType<_PlayerSettingsPanelState>();
    final canGoBack = panel != null && (ModalRoute.canPopOf(context) ?? false);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The empty leading space lets the scrim dissolve into the video without
        // fading the controls or creating a visible drawer edge.
        final compact = isCompactPlayerPanel(context);
        final leading = compact
            ? 12.0
            : (constraints.maxWidth < 400 ? 20.0 : 64.0);
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
                padding: EdgeInsets.only(left: leading, right: compact ? 4 : 8),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(
                    color: Colors.white,
                    shadows: [Shadow(color: Color(0x99000000), blurRadius: 3)],
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: compact
                            ? const EdgeInsets.fromLTRB(8, 2, 4, 2)
                            : const EdgeInsets.fromLTRB(16, 12, 8, 8),
                        child: Row(
                          children: [
                            if (canGoBack) ...[
                              IconButton(
                                tooltip: '返回上一级',
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.arrow_back_rounded),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                title,
                                style: TextStyle(
                                  fontSize: compact ? 18 : 22,
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
                              onPressed:
                                  panel?.close ??
                                  () => Navigator.of(context).pop(),
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
    padding: EdgeInsets.only(bottom: isCompactPlayerPanel(context) ? 4 : 8),
    child: Text(
      title,
      style: TextStyle(
        color: Colors.white,
        fontSize: isCompactPlayerPanel(context) ? 14 : 16,
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
  Widget build(BuildContext context) =>
      SizedBox(height: isCompactPlayerPanel(context) ? 4 : 8);
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: EdgeInsets.symmetric(
            vertical: isCompactPlayerPanel(context) ? 2 : 6,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: isCompactPlayerPanel(context) ? 14 : 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null) ...[
                      SizedBox(height: isCompactPlayerPanel(context) ? 2 : 4),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: Color(0xFFD4DCE5),
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: isCompactPlayerPanel(context) ? 6 : 12),
              Switch(
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: isCompactPlayerPanel(context)
                    ? MaterialTapTargetSize.shrinkWrap
                    : MaterialTapTargetSize.padded,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
