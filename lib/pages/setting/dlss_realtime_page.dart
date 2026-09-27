import 'dart:async';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/services/playback/dlss_realtime_player.dart';
import 'package:baka/services/playback/dlss_tool_installer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dlss_video_enhancement_page.dart';

class DlssRealtimePage extends StatefulWidget {
  const DlssRealtimePage({super.key});
  @override
  State<DlssRealtimePage> createState() => _DlssRealtimePageState();
}

class _DlssRealtimePageState extends State<DlssRealtimePage> {
  final _player = DlssRealtimePlayer();
  String _input = '';
  int _maxHeight = 1080;
  double _intensity = .7;
  bool _superResolution = true;
  bool _frameGeneration = true;
  double? _seek;
  bool _launching = false;
  bool get _busy => _launching || _player.running;

  @override
  void initState() {
    super.initState();
    _player.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _pick() async {
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择本地 SDR 视频',
        type: FileType.custom,
        allowedExtensions: ['mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', 'ts'],
      );
      final path = result?.files.single.path;
      if (mounted && !_busy && path != null) setState(() => _input = path);
    } catch (error) {
      _message('选择失败：$error');
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() => _launching = true);
    try {
      final cache = await Instances.desktopDataDirectory('dlss5-realtime');
      if (!mounted) return;
      await _player.start(
        tools: DlssToolchain.load(Instances.sp),
        inputPath: _input,
        cacheDirectory: cache,
        maxHeight: _maxHeight,
        intensity: _intensity,
        superResolution: _superResolution,
        frameGeneration: _frameGeneration,
      );
    } catch (error) {
      _message('启动失败：$error');
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  String _time(double seconds) {
    final value = seconds.floor();
    return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _player.removeListener(_refresh);
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('DLSS 5 实时播放')),
      body: !Platform.isWindows
          ? const Center(child: Text('实时增强仅支持 Windows'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text('边播放边增强', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text(
                      '视频将在独立窗口中播放，无需等待整片转换。支持本地 SDR 视频和第一条音轨；暂不显示字幕与弹幕。离开此页面会关闭播放窗口。',
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      const DlssVideoEnhancementPage(),
                                ),
                              ),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('下载并配置增强环境'),
                      ),
                    ),
                    const Text(
                      '与离线增强共用已下载的环境。首次开启帧生成会自动下载约 7.1 MB 的 NVIDIA 官方运行库。更新实时功能后需重新构建并启动 Windows 应用。',
                    ),
                    const SizedBox(height: 20),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.movie_outlined),
                        title: const Text('本地视频'),
                        subtitle: Text(_input.isEmpty ? '点击选择' : _input),
                        trailing: const Icon(Icons.folder_open_outlined),
                        onTap: _busy ? null : _pick,
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      initialValue: _maxHeight,
                      decoration: const InputDecoration(
                        labelText: '增强输入分辨率上限',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 1080, child: Text('1080p')),
                        DropdownMenuItem(
                          value: 720,
                          child: Text('720p · 减少处理量'),
                        ),
                      ],
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _maxHeight = value!),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '保持视频比例。超分在增强后将宽、高各放大 2 倍：720p → 1440p，1080p → 4K。速度不足时会跳过过期帧以保持声音同步。',
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('NVIDIA DLSS 超分辨率 · 2 倍'),
                      subtitle: Text(
                        _superResolution
                            ? (_player.running && _player.original
                                  ? '对比原片期间暂停'
                                  : _player.superResolutionActive
                                  ? '已启用'
                                  : '已选择，启动后检查支持情况')
                            : '关闭，保持增强输入尺寸',
                      ),
                      value: _superResolution,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _superResolution = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('NVIDIA DLSS 帧生成 · 2 倍'),
                      subtitle: Text(
                        _frameGeneration
                            ? (_player.running && _player.original
                                  ? '对比原片期间暂停'
                                  : _player.frameGenerationActive
                                  ? '接口已启用 · 已提交 ${_player.generatedFrames} 个生成帧'
                                  : '已选择，启动后检查 GPU 与驱动支持情况')
                            : '关闭，仅显示增强后的原始帧',
                      ),
                      value: _frameGeneration,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _frameGeneration = value),
                    ),
                    const Text(
                      '帧生成在相邻视频帧之间插入一帧；处理速度不足时不保证翻倍。对比原片时暂停超分与帧生成。视频运动和深度为估算数据，快速运动可能出现瑕疵。',
                    ),
                    const SizedBox(height: 16),
                    Text('增强强度 ${_intensity.toStringAsFixed(1)}'),
                    Slider(
                      value: _intensity,
                      min: .1,
                      max: 2,
                      divisions: 19,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _intensity = value),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy || _input.isEmpty ? null : _start,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('开始实时播放'),
                        ),
                        if (_busy)
                          OutlinedButton.icon(
                            onPressed: _player.stop,
                            icon: const Icon(Icons.stop),
                            label: const Text('停止'),
                          ),
                        if (_player.ready) ...[
                          OutlinedButton(
                            onPressed: _player.togglePause,
                            child: Text(_player.paused ? '继续' : '暂停'),
                          ),
                          OutlinedButton(
                            onPressed: _player.toggleOriginal,
                            child: Text(_player.original ? '查看增强' : '对比原片'),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(_player.status, style: theme.textTheme.titleMedium),
                    if (_busy && !_player.ready)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                    if (_player.duration > 0) ...[
                      const SizedBox(height: 12),
                      Text(
                        '${_player.resolution} · 片源 ${_player.sourceFps.toStringAsFixed(2)} fps · '
                        '处理 ${_player.renderedFps.toStringAsFixed(1)} fps · '
                        '提交显示 ${_player.presentedFps.toStringAsFixed(1)} fps · 丢帧 ${_player.droppedFrames}',
                      ),
                      Slider(
                        value: (_seek ?? _player.position).clamp(
                          0,
                          _player.duration,
                        ),
                        max: _player.duration,
                        onChanged: !_player.ready
                            ? null
                            : (value) => setState(() => _seek = value),
                        onChangeEnd: !_player.ready
                            ? null
                            : (value) {
                                _player.seek(value);
                                setState(() => _seek = null);
                              },
                      ),
                      Text(
                        '${_time(_seek ?? _player.position)} / ${_time(_player.duration)}',
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      '播放窗口快捷键：空格暂停 / 继续，D 对比原片，左右方向键跳转 10 秒，Esc 关闭。实时模式使用 GPU 估算运动，效果可能与离线模式不同。',
                    ),
                    if (_player.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(
                          _player.error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    const SizedBox(height: 16),
                    ExpansionTile(
                      title: const Text('运行日志'),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: _player.log),
                              );
                              _message('日志已复制');
                            },
                            icon: const Icon(Icons.copy),
                            label: const Text('复制日志'),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            _player.log.isEmpty ? '暂无日志' : _player.log,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
