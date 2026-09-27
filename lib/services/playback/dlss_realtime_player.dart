import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import 'dlss_tool_installer.dart';
import 'dlss_frame_generation_runtime.dart';

/// Controls the Windows D3D12 player. Only commands and telemetry cross Dart;
/// neither decoded nor enhanced video frames pass through the UI isolate.
class DlssRealtimePlayer extends ChangeNotifier {
  Process? _process;
  Process? _probeProcess;
  CancelToken? _downloadCancel;
  bool _disposed = false;
  bool _cancelled = false;
  bool running = false;
  bool ready = false;
  bool paused = false;
  bool original = false;
  String status = '选择本地 SDR 视频后启动';
  String log = '';
  String? error;
  String resolution = '';
  double duration = 0;
  double position = 0;
  double sourceFps = 0;
  double renderedFps = 0;
  double presentedFps = 0;
  int generatedFrames = 0;
  bool superResolutionActive = false;
  bool frameGenerationActive = false;
  int droppedFrames = 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _log(String line) {
    log += '$line\n';
    if (log.length > 16000) log = log.substring(log.length - 16000);
  }

  void _checkCancelled() {
    if (_cancelled || _disposed) throw const _Cancelled();
  }

  static File get backend => File(
    '${File(Platform.resolvedExecutable).parent.path}'
    '${Platform.pathSeparator}baka_dlss_realtime.exe',
  );

  Future<Map<String, dynamic>> _probe(String path, String input) async {
    final process = await Process.start(path, [
      '-v',
      'error',
      '-show_streams',
      '-show_format',
      '-of',
      'json',
      input,
    ], runInShell: false);
    _probeProcess = process;
    unawaited(process.stdin.close());
    if (_cancelled || _disposed) process.kill();
    var output = '', diagnostics = '';
    final drains = [
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).forEach(
        (chunk) {
          if (output.length < 2 * 1024 * 1024) output += chunk;
        },
      ),
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).forEach(
        (chunk) {
          if (diagnostics.length < 16000) diagnostics += chunk;
        },
      ),
    ];
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 30));
      await Future.wait(drains);
      _checkCancelled();
      if (code != 0) throw StateError('读取视频失败：$diagnostics');
      return jsonDecode(output) as Map<String, dynamic>;
    } finally {
      process.kill();
      await process.exitCode;
      await Future.wait(drains);
      _probeProcess = null;
    }
  }

  Future<void> start({
    required DlssToolchain tools,
    required String inputPath,
    required Directory cacheDirectory,
    int maxHeight = 1080,
    double intensity = .7,
    bool superResolution = true,
    bool frameGeneration = true,
  }) async {
    if (running || _disposed) return;
    running = true;
    ready = paused = original = _cancelled = false;
    error = null;
    log = '';
    duration = position = renderedFps = sourceFps = presentedFps = 0;
    generatedFrames = 0;
    superResolutionActive = frameGenerationActive = false;
    droppedFrames = 0;
    status = '正在读取视频…';
    _notify();
    final drains = <Future<void>>[];
    try {
      if (!Platform.isWindows) throw StateError('实时增强仅支持 Windows');
      if (![720, 1080].contains(maxHeight) ||
          !intensity.isFinite ||
          intensity < .1 ||
          intensity > 2) {
        throw ArgumentError('实时增强参数无效');
      }
      if (!await backend.exists()) {
        throw StateError('缺少实时播放组件，请重新构建并启动 Windows 应用（热重载无法生成组件）');
      }
      if (!await tools.isAvailable()) throw StateError('请先下载并配置 DLSS 增强环境');
      final input = File(inputPath).absolute;
      if (!await input.exists()) throw StateError('找不到本地视频');
      final ffmpeg = File(tools.ffmpeg).absolute;
      final probe = File(
        '${ffmpeg.parent.path}${Platform.pathSeparator}ffprobe.exe',
      );
      final data = await _probe(probe.path, input.path);
      _checkCancelled();
      final streams = (data['streams'] as List).cast<Map<String, dynamic>>();
      final videos = streams.where(
        (s) =>
            s['codec_type'] == 'video' &&
            (s['disposition'] as Map?)?['attached_pic'] != 1,
      );
      if (videos.isEmpty) throw StateError('视频轨道不存在');
      final video = videos.first;
      if (['smpte2084', 'arib-std-b67'].contains(video['color_transfer']) ||
          '${video['color_primaries']}'.startsWith('bt2020')) {
        throw StateError('实时增强暂不支持 HDR / BT.2020，请选择 SDR 视频');
      }
      if (video['field_order'] != null &&
          !['progressive', 'unknown'].contains(video['field_order'])) {
        throw StateError('请先将隔行视频转换为逐行视频');
      }
      final sar = video['sample_aspect_ratio'];
      if (sar != null && !['1:1', '0:1', 'N/A'].contains(sar)) {
        throw StateError('暂不支持非方形像素视频');
      }
      if (((video['side_data_list'] as List?) ?? []).any(
        (d) => d['rotation'] != null && d['rotation'] != 0,
      )) {
        throw StateError('暂不支持带旋转标记的视频');
      }
      final width = video['width'] as int, height = video['height'] as int;
      if (width < 2 || height < 2) throw StateError('视频尺寸无效');
      final parts = '${video['avg_frame_rate']}'.split('/');
      sourceFps =
          (double.tryParse(parts.first) ?? 0) /
          (parts.length > 1 ? double.tryParse(parts.last) ?? 0 : 1);
      if (!sourceFps.isFinite || sourceFps <= 0 || sourceFps > 60) {
        throw StateError('实时模式支持最高 60 fps 的片源');
      }
      duration =
          double.tryParse('${(data['format'] as Map?)?['duration']}') ??
          double.tryParse('${video['duration']}') ??
          0;
      if (!duration.isFinite || duration <= 0) throw StateError('视频时长无效');
      final ratio = [
        1.0,
        maxHeight / height,
        (maxHeight == 720 ? 1280 : 1920) / width,
      ].reduce((a, b) => a < b ? a : b);
      final outWidth = ((width * ratio / 2).floor() * 2).clamp(2, 1920);
      final outHeight = ((height * ratio / 2).floor() * 2).clamp(2, 1080);
      final scale = superResolution ? 2 : 1;
      resolution =
          '$outWidth × $outHeight → ${outWidth * scale} × ${outHeight * scale}';
      var matrix = '${video['color_space']}';
      if (['null', 'unknown', 'unspecified', 'reserved'].contains(matrix)) {
        matrix = height >= 720 ? 'bt709' : 'smpte170m';
      }
      if (!['bt709', 'smpte170m', 'bt470bg'].contains(matrix)) {
        throw StateError('暂不支持该视频的颜色矩阵：$matrix');
      }
      final audio = streams.where((s) => s['codec_type'] == 'audio');
      await cacheDirectory.create(recursive: true);
      _checkCancelled();
      var fgRuntime = '';
      if (frameGeneration) {
        final cancel = CancelToken();
        _downloadCancel = cancel;
        final installed = await DlssFrameGenerationRuntime.ensure(
          directory: Directory('${cacheDirectory.path}/runtime-dlssg'),
          cancel: cancel,
          onProgress: (value) {
            status = value;
            _notify();
          },
        );
        fgRuntime = installed.path;
        _downloadCancel = null;
      }
      _checkCancelled();
      status = '正在初始化实时增强…';
      _notify();
      final process = await Process.start(
        backend.path,
        [
          '--v2',
          '$pid',
          ffmpeg.path,
          input.path,
          File(tools.executable).absolute.parent.path,
          cacheDirectory.absolute.path,
          '$outWidth',
          '$outHeight',
          '$sourceFps',
          '$duration',
          '${video['index']}',
          audio.isEmpty ? '-1' : '${audio.first['index']}',
          '$intensity',
          matrix,
          '$scale',
          fgRuntime,
        ],
        runInShell: false,
        workingDirectory: File(tools.executable).absolute.parent.path,
      );
      _process = process;
      unawaited(process.stdin.done.catchError((Object _) {}));
      if (_cancelled || _disposed) process.kill();
      drains.add(
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach(_event),
      );
      // Bound partial lines as well as complete lines from external runtimes.
      drains.add(
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .forEach((chunk) {
              _log(
                chunk.length > 16000
                    ? chunk.substring(chunk.length - 16000)
                    : chunk,
              );
            }),
      );
      final code = await process.exitCode;
      await Future.wait(drains);
      _checkCancelled();
      if (code != 0) throw StateError('实时播放程序退出（$code），请查看下方日志');
      if (status != '播放结束') status = '播放窗口已关闭';
    } on _Cancelled {
      status = '已停止';
    } catch (exception) {
      if (_cancelled || _disposed) {
        status = '已停止';
      } else {
        error = '$exception';
        status = '实时播放失败';
        _log(error!);
      }
    } finally {
      _process?.kill();
      if (_process != null) await _process!.exitCode;
      try {
        await _process?.stdin.close();
      } catch (_) {
        /* Process exited. */
      }
      await Future.wait(drains);
      _process = null;
      _downloadCancel = null;
      running = ready = false;
      superResolutionActive = frameGenerationActive = false;
      _notify();
    }
  }

  void _event(String line) {
    if (line == 'READY') {
      ready = true;
    } else if (line.startsWith('STAT ')) {
      final values = line.split(' ');
      if (values.length == 6) {
        position = (double.tryParse(values[1]) ?? position).clamp(0, duration);
        renderedFps = double.tryParse(values[2]) ?? renderedFps;
        droppedFrames = int.tryParse(values[3]) ?? droppedFrames;
        presentedFps = double.tryParse(values[4]) ?? presentedFps;
        generatedFrames = int.tryParse(values[5]) ?? generatedFrames;
      }
    } else if (line == 'FEATURE SR active') {
      superResolutionActive = true;
      _log('NVIDIA DLSS 超分：接口执行及 GPU 完成检查通过');
    } else if (line == 'FEATURE FG active') {
      frameGenerationActive = true;
      _log('NVIDIA DLSS 帧生成：接口执行及 GPU 完成检查通过');
    } else if (line.startsWith('STATE ')) {
      final value = line.substring(6);
      if (value == 'paused') paused = true;
      if (value == 'playing') paused = false;
      status = switch (value) {
        'buffering' => '正在缓冲…',
        'playing' => '实时播放中',
        'paused' => '已暂停',
        'ended' => '播放结束',
        _ => status,
      };
    } else if (line.startsWith('COMPARE ')) {
      original = line == 'COMPARE original';
    } else {
      _log(line);
    }
    _notify();
  }

  void _command(String command) {
    if (!ready || _process == null) return;
    try {
      _process!.stdin.writeln(command);
    } on StateError {
      /* Window closed. */
    }
  }

  void togglePause() => _command(paused ? 'resume' : 'pause');
  void toggleOriginal() => _command(original ? 'compare 0' : 'compare 1');
  void seek(double seconds) {
    if (seconds.isFinite) {
      _command('seek ${seconds.clamp(0, duration).toStringAsFixed(3)}');
    }
  }

  Future<void> stop() async {
    _cancelled = true;
    _downloadCancel?.cancel('已停止');
    _probeProcess?.kill();
    final process = _process;
    if (process == null) return;
    _command('stop');
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
      await process.exitCode;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
