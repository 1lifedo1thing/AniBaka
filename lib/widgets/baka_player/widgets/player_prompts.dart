import 'package:baka/models/playback_state.dart';
import '../controller.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';

const int _nextEpisodeWaitSeconds = 95;

class PlayerPrompts extends StatelessWidget {
  const PlayerPrompts({
    required this.controller,
    required this.isFullScreen,
    required this.hasNextEpisode,
    required this.onNextEpisode,
    super.key,
  });

  final PlaybackController controller;
  final bool isFullScreen;
  final bool hasNextEpisode;
  final VoidCallback? onNextEpisode;

  @override
  Widget build(BuildContext context) {
    if (!isFullScreen) return const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        ValueListenableBuilder<PlayerOverlayState>(
          valueListenable: controller.overlay,
          builder: (context, overlay, _) => Stack(
            fit: StackFit.expand,
            children: [
              if (overlay.skipState == SkipState.showingCancel)
                _buildSkipCancelPrompt(),
              if (overlay.skipState == SkipState.waiting)
                _buildWaitingPrompt(),
              if (overlay.showJumpPrompt)
                _buildJumpPrompt(overlay.jumpPromptText),
            ],
          ),
        ),
        if (hasNextEpisode)
          ValueListenableBuilder<PlaybackPreferences>(
            valueListenable: controller.preferences,
            builder: (context, preferences, _) {
              if (!preferences.showNextEpisodeButton) {
                return const SizedBox.shrink();
              }
              return ValueListenableBuilder<PlaybackTimelineState>(
                valueListenable: controller.timeline,
                builder: (context, timeline, _) {
                  final position = timeline.position.inSeconds;
                  final duration = timeline.duration.inSeconds;
                  final remaining = duration - position;
                  if (duration <= _nextEpisodeWaitSeconds ||
                      remaining > _nextEpisodeWaitSeconds ||
                      position <= 0) {
                    return const SizedBox.shrink();
                  }
                  return _buildNextEpisodePrompt(remaining);
                },
              );
            },
          ),
      ],
    );
  }

  Widget _buildWaitingPrompt() {
    return Positioned(
      top: 64,
      right: 24,
      child: _PlayerPill(
        children: [
          Icon(
            Icons.auto_awesome,
            color: Colors.white.withValues(alpha: 0.9),
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            '可能是片头',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const _PillDivider(),
          _PillButton(
            icon: Icons.fast_forward_rounded,
            label: '跳过',
            onTap: controller.userActionSkip,
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () {
              controller.userActionCancelSkip();
              showSnackBar('已取消自动跳过');
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                color: Colors.white.withValues(alpha: 0.7),
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkipCancelPrompt() {
    return Positioned(
      top: 80,
      right: 24,
      child: _PlayerPill(
        children: [
          Icon(
            Icons.fast_forward_rounded,
            color: Colors.white.withValues(alpha: 0.9),
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            '已自动跳过片头',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const _PillDivider(),
          _PillButton(
            icon: Icons.replay_rounded,
            label: '撤销',
            onTap: () {
              controller.cancelSkipOpEd();
              showSnackBar('已返回跳过前位置');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildJumpPrompt(String text) {
    return Positioned(
      top: 120,
      right: 24,
      child: _PlayerPill(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.history,
                    color: Colors.blueAccent.shade100,
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '上次播放位置',
                    style: TextStyle(
                      color: Colors.blueAccent.shade100,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              Text(
                text,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          _PillButton(
            label: '继续',
            icon: Icons.play_arrow_rounded,
            color: Colors.blueAccent,
            onTap: controller.performJumpToPosition,
          ),
          const SizedBox(width: 8),
          _PillButton(
            icon: Icons.close_rounded,
            color: Colors.white,
            isClose: true,
            onTap: controller.hideJumpPrompt,
          ),
        ],
      ),
    );
  }

  Widget _buildNextEpisodePrompt(int remaining) {
    return Positioned(
      bottom: 100,
      right: 24,
      child: InkWell(
        onTap: onNextEpisode,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
              width: 0.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: (_nextEpisodeWaitSeconds - remaining) /
                          _nextEpisodeWaitSeconds,
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                      color: Colors.blueAccent,
                      strokeWidth: 2,
                    ),
                    Text(
                      '$remaining',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '下一集',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.skip_next_rounded,
                color: Colors.white.withValues(alpha: 0.9),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayerPill extends StatelessWidget {
  const _PlayerPill({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _PillDivider extends StatelessWidget {
  const _PillDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 12,
      width: 1,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Colors.white.withValues(alpha: 0.2),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.onTap,
    this.label,
    this.color,
    this.isClose = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? label;
  final Color? color;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Colors.blueAccent.shade100;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: label != null ? 10 : 6,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: isClose
              ? Colors.white.withValues(alpha: 0.1)
              : effectiveColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isClose
                ? Colors.white.withValues(alpha: 0.2)
                : effectiveColor.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isClose ? Colors.white70 : effectiveColor, size: 14),
            if (label != null) ...[
              const SizedBox(width: 4),
              Text(
                label!,
                style: TextStyle(
                  color: effectiveColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

