import 'package:baka/widgets/settings/dlss_effects_editor.dart';
import 'dart:io';

import 'package:baka/widgets/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:baka/services/playback/dlss_global_playback.dart';

class LabsSettingsPage extends StatelessWidget {
  const LabsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('实验室')),
    body: !Platform.isWindows
        ? const Center(child: Text('实验室功能当前仅支持 Windows'))
        : Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: ListenableBuilder(
                listenable: DlssGlobalPlayback.instance,
                builder: (context, _) => ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(
                      '尝试正在开发中的功能',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text('实验功能可单独配置。设备兼容性和处理效果可能随版本变化。'),
                    const SizedBox(height: 24),
                    const SettingsSectionHeader('视频增强'),
                    SwitchListTile(
                      title: const Text('所有内置播放启用 DLSS 5'),
                      subtitle: const Text(
                        '适用于在线番剧、本地文件及预览。增强强度、超分和帧生成可在下方调整。',
                      ),
                      value: DlssGlobalPlayback.instance.enabled,
                      onChanged: DlssGlobalPlayback.instance.busy
                          ? null
                          : DlssGlobalPlayback.instance.setEnabled,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(DlssGlobalPlayback.instance.status),
                    ),
                    if (DlssGlobalPlayback.instance.error != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          DlssGlobalPlayback.instance.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (DlssGlobalPlayback.instance.busy) ...[
                      const LinearProgressIndicator(),
                      TextButton(
                        onPressed: DlssGlobalPlayback.instance.cancelSetup,
                        child: const Text('取消配置'),
                      ),
                    ],
                    const DlssEffectsEditor(),
                    if (DlssGlobalPlayback.instance.enabled)
                      SwitchListTile(
                        title: const Text('播放时启用 DLSS'),
                        subtitle: const Text(
                          '与播放器中的 DLSS 按钮同步。播放器内点击开关，长按或右键调整效果。',
                        ),
                        value: DlssGlobalPlayback.instance.playbackEnabled,
                        onChanged: DlssGlobalPlayback.instance.busy
                            ? null
                            : DlssGlobalPlayback.instance.setPlaybackEnabled,
                      ),
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '开关默认关闭，修改会应用到当前画面并保存。首次开启自动配置运行库（约 236 MiB，开启帧生成另需约 7 MiB）。仅增强本机 Windows 视频输出；投屏设备和外部播放器不受影响。不支持的画面会回退到普通播放。',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
  );
}
