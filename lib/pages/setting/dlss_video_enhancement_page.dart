import 'dart:async';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/services/playback/dlss_video_enhancement.dart';
import 'package:baka/services/playback/dlss_tool_installer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

class DlssVideoEnhancementPage extends StatefulWidget {
  const DlssVideoEnhancementPage({super.key});

  @override
  State<DlssVideoEnhancementPage> createState() =>
      _DlssVideoEnhancementPageState();
}

class _DlssVideoEnhancementPageState extends State<DlssVideoEnhancementPage> {
  static const _resultKey = 'dlss5_last_result';
  static const _originalKey = 'dlss5_last_original';
  final _job = DlssVideoEnhancement();
  final _installer = DlssToolInstaller();
  late String _tool;
  late String _ffmpeg;
  String _input = '';
  String? _result;
  String? _original;
  double _intensity = 0.7;
  int _scale = 1;
  bool _starting = false;
  bool _configuring = false;
  bool _configurationAttempted = false;
  String? _configurationError;
  bool _toolsReady = false;
  bool _checkingTools = true;
  int _checkRevision = 0;

  bool get _busy =>
      _starting || _job.running || _configuring || _installer.running;

  @override
  void initState() {
    super.initState();
    final tools = DlssToolchain.load(Instances.sp);
    _tool = tools.executable;
    _ffmpeg = tools.ffmpeg;
    _result = Instances.sp.getString(_resultKey);
    _original = Instances.sp.getString(_originalKey);
    _job.addListener(_refresh);
    _installer.addListener(_refresh);
    unawaited(_checkTools());
  }

  Future<void> _checkTools() async {
    final revision = ++_checkRevision;
    if (mounted) setState(() => _checkingTools = true);
    var ready = false;
    try {
      ready = await DlssToolchain(
        executable: _tool,
        ffmpeg: _ffmpeg,
      ).isAvailable();
    } on FileSystemException {
      // Removed or inaccessible installations can be downloaded again.
    }
    if (!mounted || revision != _checkRevision) return;
    setState(() {
      _toolsReady = ready;
      _checkingTools = false;
    });
  }

  Future<void> _configure() async {
    if (_busy) return;
    setState(() {
      _configuring = true;
      _configurationAttempted = true;
      _configurationError = null;
    });
    try {
      final directory = await Instances.desktopDataDirectory('tools/dlss5');
      if (!mounted) return;
      final tools = await _installer.install(directory);
      if (tools == null || !mounted) return;
      await tools.save(Instances.sp);
      if (!mounted) return;
      setState(() {
        _tool = tools.executable;
        _ffmpeg = tools.ffmpeg;
      });
      await _checkTools();
      if (_toolsReady) {
        _message('环境已配置，可以选择视频开始增强');
      } else if (mounted) {
        setState(() => _configurationError = '配置已保存，但部分工具文件无法访问，请重试或手动配置');
      }
    } catch (error) {
      if (mounted) setState(() => _configurationError = '配置未完成：$error');
      _message('配置未完成：$error');
    } finally {
      if (mounted) setState(() => _configuring = false);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pick(String kind) async {
    try {
      final selection = await FilePicker.pickFiles(
        dialogTitle: switch (kind) {
          'tool' => '选择 video2dlssnr.exe',
          'ffmpeg' => '选择 ffmpeg.exe',
          _ => '选择本地 SDR 视频',
        },
        type: FileType.custom,
        allowedExtensions: kind == 'video'
            ? ['mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', 'ts']
            : ['exe'],
      );
      final path = selection?.files.single.path;
      if (!mounted || path == null || _busy) return;
      if (kind == 'tool') {
        if (File(path).uri.pathSegments.last.toLowerCase() !=
            'video2dlssnr.exe') {
          _message('请选择 video2dlssnr.exe');
          return;
        }
        await DlssToolchain(
          executable: path,
          ffmpeg: _ffmpeg,
        ).save(Instances.sp);
        if (!mounted) return;
        setState(() => _tool = path);
        await _checkTools();
      } else if (kind == 'ffmpeg') {
        if (File(path).uri.pathSegments.last.toLowerCase() != 'ffmpeg.exe') {
          _message('请选择 ffmpeg.exe');
          return;
        }
        await DlssToolchain(executable: _tool, ffmpeg: path).save(Instances.sp);
        if (!mounted) return;
        setState(() => _ffmpeg = path);
        await _checkTools();
      } else {
        setState(() => _input = path);
      }
    } catch (error) {
      _message('选择文件失败：$error');
    }
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() => _starting = true);
    try {
      final directory = await Instances.desktopDataDirectory('dlss5-cache');
      if (!mounted) return;
      final input = _input;
      final result = await _job.enhance(
        inputPath: input,
        executablePath: _tool,
        ffmpegPath: _ffmpeg,
        cacheDirectory: directory,
        intensity: _intensity,
        scale: _scale,
      );
      if (!mounted || result == null) return;
      setState(() {
        _result = result;
        _original = input;
      });
      await Instances.sp.setString(_resultKey, result);
      await Instances.sp.setString(_originalKey, input);
    } catch (error) {
      _message('无法开始增强：$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _playResult() async {
    final result = _result;
    if (result == null) return;
    if (!await File(result).exists()) {
      _message('增强文件已移动或删除，请重新处理');
      return;
    }
    final original = _original;
    final hasOriginal = original != null && await File(original).exists();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _DlssPreviewPage(
          result: result,
          original: hasOriginal ? original : null,
        ),
      ),
    );
  }

  Future<void> _openFolder() async {
    try {
      final directory = await Instances.desktopDataDirectory('dlss5-cache');
      final result = await OpenFilex.open(directory.path);
      if (result.type != ResultType.done) _message('打开文件夹失败：${result.message}');
    } catch (error) {
      _message('打开文件夹失败：$error');
    }
  }

  Future<void> _openProject() async {
    try {
      final opened = await launchUrl(
        Uri.parse(
          'https://github.com/DaniilSokolyuk/video2dlssnr/releases/tag/v1.4.1',
        ),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) _message('无法打开项目页面');
    } catch (error) {
      _message('无法打开项目页面：$error');
    }
  }

  @override
  void dispose() {
    _job.removeListener(_refresh);
    _job.dispose();
    _installer.removeListener(_refresh);
    _installer.dispose();
    super.dispose();
  }

  Widget _fileTile(String title, String value, String kind, IconData icon) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(
        value.isEmpty ? '点击选择' : value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.folder_open_outlined),
      enabled: !_busy,
      onTap: () => _pick(kind),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _message('任务进行中，请先取消，或等待增强完成');
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('DLSS 5 实验性增强')),
        body: !Platform.isWindows
            ? const Center(child: Text('此功能仅支持 Windows'))
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 840),
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Text(
                        '将本地视频处理为增强副本',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '处理完成后可播放并与原片切换对比。当前支持 SDR 视频，音轨、内嵌字幕和章节随结果保存。'
                        '处理可能较慢，请保持此页面打开。',
                      ),
                      const SizedBox(height: 20),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _checkingTools
                                    ? '正在检查增强环境…'
                                    : _toolsReady
                                    ? '增强环境已就绪'
                                    : '配置增强环境',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                '一键下载增强程序和 FFmpeg，约 346 MB。完成后自动配置，无需手动选择程序。'
                                '需要 NVIDIA RTX 显卡及 616.56 或更新驱动。',
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: [
                                  FilledButton.icon(
                                    onPressed: _busy || _checkingTools
                                        ? null
                                        : _configure,
                                    icon: const Icon(Icons.download_rounded),
                                    label: Text(
                                      _toolsReady
                                          ? '重新下载并配置'
                                          : _installer.error != null
                                          ? '重试下载并配置'
                                          : '下载并配置',
                                    ),
                                  ),
                                  if (_configuring)
                                    OutlinedButton(
                                      onPressed: _installer.running
                                          ? _installer.cancel
                                          : null,
                                      child: const Text('取消配置'),
                                    ),
                                ],
                              ),
                              if (_configurationAttempted) ...[
                                const SizedBox(height: 12),
                                if (_configuring)
                                  LinearProgressIndicator(
                                    value: _installer.progress,
                                  ),
                                const SizedBox(height: 8),
                                Text(_installer.status),
                                if (_installer.error != null)
                                  SelectableText(
                                    _installer.error!,
                                    style: TextStyle(color: colors.error),
                                  ),
                                if (_configurationError != null)
                                  SelectableText(
                                    _configurationError!,
                                    style: TextStyle(color: colors.error),
                                  ),
                              ],
                              ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                title: const Text('手动配置与下载来源'),
                                children: [
                                  _fileTile(
                                    '增强程序',
                                    _tool,
                                    'tool',
                                    Icons.auto_awesome_outlined,
                                  ),
                                  _fileTile(
                                    'FFmpeg',
                                    _ffmpeg,
                                    'ffmpeg',
                                    Icons.video_settings_outlined,
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 8),
                                    child: Text(
                                      '下载来源：video2dlssnr v1.4.1（社区项目）和 Gyan FFmpeg 9.0.2。'
                                      '下载后校验 SHA-256。手动配置时，保留增强程序同目录运行库，'
                                      '并将 ffprobe.exe 与 ffmpeg.exe 放在同一目录。',
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: _openProject,
                                      icon: const Icon(Icons.open_in_new),
                                      label: const Text('查看增强程序项目'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Card(
                        child: Column(
                          children: [
                            _fileTile(
                              '本地视频',
                              _input,
                              'video',
                              Icons.movie_outlined,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '增强强度 ${_intensity.toStringAsFixed(1)}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Slider(
                        value: _intensity,
                        min: 0.1,
                        max: 2,
                        divisions: 19,
                        label: _intensity.toStringAsFixed(1),
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _intensity = value),
                      ),
                      const Text('较低强度适合先观察动画线条和人物细节的变化。'),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<int>(
                        initialValue: _scale,
                        decoration: const InputDecoration(
                          labelText: '输出尺寸',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 1, child: Text('原尺寸增强')),
                          DropdownMenuItem(
                            value: 2,
                            child: Text('2 倍尺寸：超分辨率 + 增强'),
                          ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _scale = value ?? 1),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed:
                                _busy ||
                                    _input.isEmpty ||
                                    !_toolsReady ||
                                    _checkingTools
                                ? null
                                : _start,
                            icon: const Icon(Icons.auto_awesome),
                            label: const Text('开始增强'),
                          ),
                          if (_job.running)
                            OutlinedButton.icon(
                              onPressed: _job.running ? _job.cancel : null,
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const Text('取消'),
                            ),
                          TextButton.icon(
                            onPressed: _openFolder,
                            icon: const Icon(Icons.folder_outlined),
                            label: const Text('增强文件夹'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_starting || _job.running) ...[
                        LinearProgressIndicator(value: _job.progress),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        _job.status,
                        style: TextStyle(
                          color: _job.error == null
                              ? colors.onSurface
                              : colors.error,
                        ),
                      ),
                      if (_job.running && _job.processingFps > 0)
                        Text(
                          '${_job.progress == null ? '' : '${(_job.progress! * 100).floor()}% · '}'
                          '已编码 ${_job.completedFps.toStringAsFixed(1)} 帧/秒 · '
                          '增强 ${_job.processingFps.toStringAsFixed(1)} 帧/秒',
                        ),
                      if (_job.error != null) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          _job.error!,
                          style: TextStyle(color: colors.error),
                        ),
                      ],
                      if (_result != null) ...[
                        const SizedBox(height: 20),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '上次完成的增强视频',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 8),
                                if (_original != null)
                                  Text(
                                    '原片：${File(_original!).uri.pathSegments.last}',
                                  ),
                                SelectableText(_result!),
                                const SizedBox(height: 12),
                                FilledButton.tonalIcon(
                                  onPressed: _busy ? null : _playResult,
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('播放 / 对比原片'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      const Text(
                        '增强副本保存在文档目录的 baka/dlss5-cache 文件夹中，可通过“增强文件夹”管理。'
                        '社区运行库的兼容性取决于显卡、驱动及版本，应用会在处理失败时保留原片。',
                        style: TextStyle(fontSize: 13),
                      ),
                      if (_job.log.isNotEmpty)
                        ExpansionTile(
                          title: const Text('处理日志'),
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: _job.log),
                                  );
                                  _message('日志已复制');
                                },
                                icon: const Icon(Icons.copy),
                                label: const Text('复制日志'),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: SelectableText(
                                _job.log,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// A separate preview session avoids applying the user's Anime4K settings to
/// the already enhanced result and leaves normal playback preferences intact.
class _DlssPreviewPage extends StatefulWidget {
  const _DlssPreviewPage({required this.result, this.original});
  final String result;
  final String? original;

  @override
  State<_DlssPreviewPage> createState() => _DlssPreviewPageState();
}

class _DlssPreviewPageState extends State<_DlssPreviewPage> {
  late final Player _player;
  late final VideoController _video;
  StreamSubscription<String>? _errors;
  bool _enhanced = true;
  bool _switching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    _player = Player();
    _video = VideoController(_player);
    _errors = _player.stream.error.listen((error) {
      if (mounted) setState(() => _error = error);
    });
    unawaited(_open(true, initial: true));
  }

  Future<void> _open(bool enhanced, {bool initial = false}) async {
    if (_switching) return;
    setState(() {
      _switching = true;
      _error = null;
    });
    final position = initial ? Duration.zero : _player.state.position;
    final playing = initial || _player.state.playing;
    try {
      final path = enhanced ? widget.result : widget.original!;
      await _player.open(Media(path, start: position), play: playing);
      if (mounted) setState(() => _enhanced = enhanced);
    } catch (error) {
      if (mounted) setState(() => _error = '播放失败：$error');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  void dispose() {
    unawaited(_errors?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_enhanced ? 'DLSS 5 增强结果' : '原片'),
      actions: [
        if (widget.original != null)
          TextButton(
            onPressed: _switching ? null : () => _open(!_enhanced),
            child: Text(_enhanced ? '同位置查看原片' : '同位置查看增强结果'),
          ),
      ],
    ),
    body: Column(
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(_error!),
          ),
        Expanded(child: Video(controller: _video)),
      ],
    ),
  );
}
