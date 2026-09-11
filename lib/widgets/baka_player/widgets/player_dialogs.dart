import 'package:baka/models/playback_state.dart';
import '../controller.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';

Future<void> showSpeedDialog(
  BuildContext context,
  PlaybackController controller,
) async {
  const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0];
  final current = controller.core.value.playbackRate;
  final result = await showAppSelectionDialog<double>(
    context,
    title: '播放倍速',
    options: speeds
        .map((speed) => SelectionOption(value: speed, label: '${speed}x'))
        .toList(),
    currentValue: current,
  );
  if (result != null) {
    controller.setRate(result);
  }
}

Future<void> showVideoFitDialog(
  BuildContext context,
  PlaybackController controller,
) async {
  final currentFit = controller.preferences.value.videoFit;
  final result = await showAppSelectionDialog<({BoxFit fit, String description})>(
    context,
    title: '画面比例',
    options: PlaybackController.videoFitTypes
        .map((type) => SelectionOption(value: type, label: type.description))
        .toList(),
    currentValue: PlaybackController.videoFitTypes.firstWhere(
      (type) => type.fit == currentFit,
      orElse: () => PlaybackController.videoFitTypes.first,
    ),
  );
  if (result != null) {
    controller.setVideoFit(result.fit, result.description);
  }
}

Future<void> showVideoEnhancementModeDialog(
  BuildContext context,
  PlaybackController controller,
) async {
  const options = <SelectionOption<VideoEnhancementMode>>[
    SelectionOption(
      value: VideoEnhancementMode.low,
      label: '低',
      subtitle: '轻度锐化，画面更通透，性能开销小',
    ),
    SelectionOption(
      value: VideoEnhancementMode.medium,
      label: '中',
      subtitle: '线条更锐利，画面更干净，效果明显',
    ),
    SelectionOption(
      value: VideoEnhancementMode.high,
      label: '高',
      subtitle: '大幅提升清晰度，改善显著',
    ),
    SelectionOption(
      value: VideoEnhancementMode.ultra,
      label: '超高',
      subtitle: '负载高，线条与细节还原最佳',
    ),
  ];
  final result = await showAppSelectionDialog<VideoEnhancementMode>(
    context,
    title: 'Anime4K 增强档位',
    options: options,
    currentValue: controller.preferences.value.videoEnhancementMode,
  );
  if (result != null) {
    try {
      await controller.setVideoEnhancementMode(result);
      showSnackBar('视频增强：${result.label}');
    } catch (error) {
      showSnackBar('视频增强切换失败：$error');
    }
  }
}

