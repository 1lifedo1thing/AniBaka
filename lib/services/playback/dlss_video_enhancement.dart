import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Offline adapter for video2dlssnr v1.4.1's raw RGBA pipe protocol.
/// Each process is owned by this job; no shell or global driver changes are used.
class DlssVideoEnhancement extends ChangeNotifier {
  final List<Process> _processes = [];
  bool _disposed = false;
  bool _cancelled = false;
  bool running = false;
  String status = '配置环境并选择视频后开始';
  String log = '';
  double? progress;
  double processingFps = 0;
  double completedFps = 0;
  String? outputPath;
  String? error;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkCancelled() {
    if (_cancelled) throw const _DlssCancelled();
  }

  void _appendLog(String text) {
    log += '$text\n';
    // Keep diagnostic output bounded, including unusually long runtime lines.
    if (log.length > 16000) log = log.substring(log.length - 16000);
  }

  Future<Process> _start(String executable, List<String> arguments) async {
    _checkCancelled();
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: File(executable).absolute.parent.path,
      runInShell: false,
    );
    _processes.add(process);
    if (_cancelled) {
      process.kill();
      throw const _DlssCancelled();
    }
    return process;
  }

  void cancel() {
    if (!running) return;
    _cancelled = true;
    status = '正在取消…';
    _killProcesses();
    _notify();
  }

  void _killProcesses() {
    for (final process in _processes) {
      process.kill();
    }
  }

  Future<Map<String, dynamic>> _probe(String executable, String input) async {
    final process = await _start(executable, [
      '-v',
      'error',
      '-show_streams',
      '-show_format',
      '-of',
      'json',
      input,
    ]);
    unawaited(process.stdin.close());
    var stdoutText = '';
    var stderrText = '';
    final out = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) {
          if (stdoutText.length < 2 * 1024 * 1024) stdoutText += chunk;
        });
    final err = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) {
          if (stderrText.length < 16000) stderrText += chunk;
        });
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 60));
      await Future.wait([out, err]);
      _checkCancelled();
      if (code != 0) throw StateError('无法读取视频信息：$stderrText');
      return jsonDecode(stdoutText) as Map<String, dynamic>;
    } on TimeoutException {
      process.kill();
      throw StateError('读取视频信息超时');
    } finally {
      if (_cancelled) process.kill();
    }
  }

  /// Results are published only after all three processes succeed and their
  /// frame counts agree. Failed/cancelled jobs keep no playable partial output.
  Future<String?> enhance({
    required String inputPath,
    required String executablePath,
    required String ffmpegPath,
    required Directory cacheDirectory,
    double intensity = 0.7,
    int scale = 1,
  }) async {
    if (running) return null;
    running = true;
    _cancelled = false;
    error = null;
    outputPath = null;
    log = '';
    progress = null;
    processingFps = 0;
    completedFps = 0;
    status = '正在读取视频信息…';
    _notify();
    File? partial;
    Directory? jobDirectory;
    final stopwatch = Stopwatch()..start();
    try {
      if (!Platform.isWindows) throw StateError('DLSS 5 实验性增强仅支持 Windows');
      if (![1, 2].contains(scale) ||
          !intensity.isFinite ||
          intensity < 0.1 ||
          intensity > 2) {
        throw ArgumentError('增强参数超出支持范围');
      }
      final source = File(inputPath).absolute;
      final executable = File(executablePath).absolute;
      final ffmpeg = File(ffmpegPath).absolute;
      final ffprobe = File(
        '${ffmpeg.parent.path}${Platform.pathSeparator}ffprobe.exe',
      );
      for (final file in [source, executable, ffmpeg, ffprobe]) {
        if (!await file.exists()) throw StateError('找不到文件：${file.path}');
      }
      if (executable.uri.pathSegments.last.toLowerCase() !=
          'video2dlssnr.exe') {
        throw StateError('请选择 video2dlssnr.exe');
      }
      if (ffmpeg.uri.pathSegments.last.toLowerCase() != 'ffmpeg.exe') {
        throw StateError('请选择 ffmpeg.exe，并将 ffprobe.exe 放在同一目录');
      }
      final runtime = File(
        '${executable.parent.path}${Platform.pathSeparator}nvngx_dlssnr.dll',
      );
      if (!await runtime.exists()) {
        throw StateError('增强程序旁缺少 nvngx_dlssnr.dll，请选择完整运行包中的程序');
      }
      final metadata = await _probe(ffprobe.path, source.path);
      final streams = (metadata['streams'] as List)
          .cast<Map<String, dynamic>>();
      final videos = streams.where(
        (s) =>
            s['codec_type'] == 'video' &&
            (s['disposition'] as Map?)?['attached_pic'] != 1,
      );
      if (videos.isEmpty) throw StateError('文件中没有视频轨道');
      final video = videos.first;
      final width = video['width'] as int;
      final height = video['height'] as int;
      if (width < 2 ||
          height < 2 ||
          width.isOdd ||
          height.isOdd ||
          width * scale > 4096 ||
          height * scale > 4096) {
        throw StateError('当前支持偶数宽高，输出宽高最多 4096 像素；请降低输出倍率');
      }
      if (['smpte2084', 'arib-std-b67'].contains(video['color_transfer']) ||
          '${video['color_primaries']}'.startsWith('bt2020')) {
        throw StateError('第一版支持 SDR 视频，请先选择 SDR 片源');
      }
      if (video['field_order'] != null &&
          !['unknown', 'progressive'].contains(video['field_order'])) {
        throw StateError('暂不支持隔行视频，请先转换为逐行视频');
      }
      final sar = video['sample_aspect_ratio'];
      if (sar != null && !['1:1', '0:1', 'N/A'].contains(sar)) {
        throw StateError('暂不支持非方形像素视频，请先转换为方形像素');
      }
      final sideData = (video['side_data_list'] as List?) ?? const [];
      if (sideData.any(
        (data) => data['rotation'] != null && data['rotation'] != 0,
      )) {
        throw StateError('暂不支持带旋转标记的视频，请先转换方向');
      }
      final rate = '${video['avg_frame_rate']}';
      final fraction = rate.split('/');
      final numerator = double.tryParse(fraction.first) ?? 0;
      final denominator = fraction.length == 2
          ? double.tryParse(fraction.last) ?? 0
          : 1.0;
      final fps = denominator > 0 ? numerator / denominator : 0.0;
      if (!fps.isFinite || fps <= 0 || fps > 120) {
        throw StateError('无法识别受支持的视频帧率');
      }
      final duration =
          double.tryParse('${video['duration']}') ??
          double.tryParse('${(metadata['format'] as Map?)?['duration']}') ??
          0;
      if (!duration.isFinite || duration <= 0) throw StateError('无法识别视频时长');
      final estimatedFrames = (duration * fps).round();
      final formatStart =
          double.tryParse('${(metadata['format'] as Map?)?['start_time']}') ??
          0;
      final videoStart =
          double.tryParse('${video['start_time']}') ?? formatStart;
      final videoOffset = videoStart - formatStart;
      if (!videoOffset.isFinite) throw StateError('无法识别视频时间戳');
      String colorTag(String key, String fallback) {
        final value = video[key] as String?;
        return value == null ||
                ['unknown', 'reserved', 'unspecified'].contains(value)
            ? fallback
            : value;
      }

      final matrix = colorTag(
        'color_space',
        height >= 720 ? 'bt709' : 'smpte170m',
      );
      final primaries = colorTag('color_primaries', matrix);
      final transfer = colorTag('color_transfer', 'bt709');
      final size = '${width * scale}x${height * scale}';
      await cacheDirectory.create(recursive: true);
      jobDirectory = await cacheDirectory.createTemp('dlss5-');
      partial = File(
        '${jobDirectory.path}${Platform.pathSeparator}enhanced.partial.mkv',
      );
      status = '正在增强 $width×$height → ${width * scale}×${height * scale}';
      _notify();
      // CFR sampling keeps the raw frame stream aligned with the original
      // timeline, including variable frame rate inputs.
      final decodeArgs = [
        '-nostdin',
        '-xerror',
        '-nostats',
        '-progress',
        'pipe:2',
        '-v',
        'error',
        '-noautorotate',
        '-i',
        source.path,
        '-map',
        '0:${video['index']}',
        '-an',
        '-sn',
        '-dn',
        '-vf',
        'setpts=PTS-STARTPTS,fps=$rate,'
            'setparams=colorspace=$matrix:color_primaries=$primaries:color_trc=$transfer,'
            'scale=flags=lanczos+accurate_rnd+full_chroma_int,format=rgba',
        '-f',
        'rawvideo',
        '-fps_mode',
        'passthrough',
        'pipe:1',
      ];
      final neuralArgs = [
        '--nr-video',
        '--nr-in',
        '${width}x$height',
        '--nr-style',
        '1',
        '--nr-intensity',
        intensity.toStringAsFixed(2),
        '--nr-local-structure',
        '1',
        '--nr-local-tone',
        '1',
        '--nr-detail',
        '1',
        '--nr-color',
        '0',
        '--nr-ui-correction',
        '0',
        '--nr-motion',
        '1',
        '--nr-motion-engine',
        'auto',
        '--nr-arch-spoof',
        '1',
        '--dll-dir',
        executable.parent.path,
        if (scale != 1) ...[
          '--nr-width',
          '${width * scale}',
          '--nr-height',
          '${height * scale}',
        ],
      ];
      final encodeArgs = [
        '-nostdin',
        '-n',
        '-xerror',
        '-nostats',
        '-progress',
        'pipe:1',
        '-v',
        'error',
        '-f',
        'rawvideo',
        '-pix_fmt',
        'rgba',
        '-s',
        size,
        '-r',
        rate,
        '-itsoffset',
        videoOffset.toStringAsFixed(6),
        '-i',
        'pipe:0',
        '-i',
        source.path,
        '-map',
        '0:v:0',
        '-map',
        '1:a?',
        '-map',
        '1:s?',
        '-map',
        '1:t?',
        '-map_metadata',
        '1',
        '-map_chapters',
        '1',
        '-c:a',
        'copy',
        '-c:s',
        'copy',
        '-c:t',
        'copy',
        '-vf',
        'scale=out_color_matrix=$matrix:out_range=tv:'
            'flags=lanczos+accurate_rnd+full_chroma_int,format=yuv420p,'
            'setparams=colorspace=$matrix:color_primaries=$primaries:color_trc=$transfer:range=tv',
        '-c:v',
        'h264_nvenc',
        '-fps_mode',
        'passthrough',
        '-preset',
        'p4',
        '-rc',
        'vbr',
        '-cq',
        '18',
        '-b:v',
        '0',
        '-colorspace',
        matrix,
        '-color_primaries',
        primaries,
        '-color_trc',
        transfer,
        '-color_range',
        'tv',
        partial.path,
      ];
      Process? decoder;
      Process? neural;
      Process? encoder;
      final drains = <Future<void>>[];
      String? stageFailure;
      var decodedBytes = 0;
      var enhancedBytes = 0;
      var completedFrames = 0;
      var encodedFrames = 0;
      var decodedFrames = 0;
      var decodedFinished = false;
      var encodedFinished = false;
      final nativePipeline = File(
        '${File(Platform.resolvedExecutable).parent.path}'
        '${Platform.pathSeparator}baka_dlss_pipeline.exe',
      );
      final usesNativePipe = await nativePipeline.exists();
      final progressPattern = RegExp(r'^NRPROG (\d+) ([\d.]+)');
      final donePattern = RegExp(r'done: (\d+) frames');
      var lastNotification = 0;
      void onLine(String stage, String line) {
        if (line.isEmpty) return;
        final update = stage == '增强' ? progressPattern.firstMatch(line) : null;
        if (update != null) {
          processingFps = double.tryParse(update[2]!) ?? 0;
        } else if (stage != '增强' && RegExp(r'^[a-zA-Z0-9_]+=').hasMatch(line)) {
          // FFmpeg's progress stream shares a diagnostic pipe with stderr.
          if (line.startsWith('frame=')) {
            final count = int.tryParse(line.substring(6).trim());
            if (stage == '解码') {
              decodedFrames = count ?? decodedFrames;
            } else if (stage == '编码') {
              encodedFrames = count ?? encodedFrames;
              completedFps =
                  encodedFrames /
                  (stopwatch.elapsedMilliseconds / 1000).clamp(
                    0.001,
                    double.infinity,
                  );
              progress = (encodedFrames / estimatedFrames).clamp(0, 0.99);
            }
          } else if (stage == '解码' &&
              usesNativePipe &&
              line.startsWith('total_size=')) {
            decodedBytes =
                int.tryParse(line.substring(11).trim()) ?? decodedBytes;
          } else if (line == 'progress=end') {
            if (stage == '解码') decodedFinished = true;
            if (stage == '编码') encodedFinished = true;
          }
        } else {
          _appendLog('[$stage] $line');
          if (stage == '增强') {
            final done = donePattern.firstMatch(line);
            if (done != null) completedFrames = int.parse(done[1]!);
          }
        }
        if (stopwatch.elapsedMilliseconds - lastNotification >= 250) {
          lastNotification = stopwatch.elapsedMilliseconds;
          _notify();
        }
      }

      Future<void> drain(Process process, String stage) async {
        var pending = '';
        await for (final chunk in process.stderr.transform(
          const Utf8Decoder(allowMalformed: true),
        )) {
          pending += chunk;
          final lines = pending.split(RegExp(r'[\r\n]'));
          pending = lines.removeLast();
          if (pending.length > 16000) {
            pending = pending.substring(pending.length - 16000);
          }
          for (final line in lines.where((line) => line.isNotEmpty)) {
            onLine(stage, line);
          }
        }
        onLine(stage, pending);
      }

      Future<int> watch(Process process, String stage) async {
        final code = await process.exitCode;
        if (code != 0 && !_cancelled) {
          stageFailure ??= '$stage 程序退出，错误码 $code';
          _killProcesses();
        }
        return code;
      }

      Future<void> pipe(Stream<List<int>> from, IOSink to) async {
        // A broken pipe can also complete IOSink.done with an error before
        // close() is reached. The transfer below reports the actual failure.
        unawaited(to.done.catchError((Object _) {}));
        try {
          await to.addStream(from);
          await to.close();
        } catch (exception) {
          if (!_cancelled) {
            stageFailure ??= '帧传输中断：$exception';
            _killProcesses();
          }
        }
      }

      try {
        if (usesNativePipe) {
          _appendLog('[管道] Windows 原生直连；原始帧不经过 Flutter 主线程');
          final commands = [
            [ffmpeg.path, ...decodeArgs],
            [executable.path, ...neuralArgs],
            [ffmpeg.path, ...encodeArgs],
          ];
          final pipeline = await _start(nativePipeline.path, [
            '--v1',
            '$pid',
            for (final command in commands) ...[
              '${command.length}',
              ...command,
            ],
          ]);
          unawaited(pipeline.stdin.close());
          drains.add(drain(pipeline, '管道'));
          drains.add(
            pipeline.stdout
                .transform(const Utf8Decoder(allowMalformed: true))
                .transform(const LineSplitter())
                .forEach((line) {
                  if (line.length < 2 || line[1] != '\t') return;
                  final payload = line.substring(2);
                  final stage = const {
                    'D': '解码',
                    'N': '增强',
                    'E': '编码',
                  }[line[0]];
                  if (stage != null) {
                    onLine(stage, payload);
                  } else if (line[0] == 'X') {
                    final exit = payload.split('\t');
                    if (exit.length == 2 && exit[1] != '0') {
                      final index = int.tryParse(exit[0]);
                      final name =
                          const {0: '解码', 1: '增强', 2: '编码'}[index] ?? '管道';
                      final message = '$name 程序退出，错误码 ${exit[1]}';
                      _appendLog(message);
                      if (stageFailure == null ||
                          stageFailure!.startsWith('管道 程序退出')) {
                        stageFailure = message;
                      }
                    }
                  }
                }),
          );
          await watch(pipeline, '管道');
          await Future.wait(drains);
        } else {
          _appendLog('[管道] 兼容传输模式；重新构建 Windows 版可启用原生直连');
          decoder = await _start(ffmpeg.path, decodeArgs);
          drains.add(drain(decoder, '解码'));
          unawaited(decoder.stdin.close());
          final decodeExit = watch(decoder, '解码');
          neural = await _start(executable.path, neuralArgs);
          drains.add(drain(neural, '增强'));
          final neuralExit = watch(neural, '增强');
          encoder = await _start(ffmpeg.path, encodeArgs);
          drains.add(drain(encoder, '编码'));
          drains.add(
            encoder.stdout
                .transform(const Utf8Decoder(allowMalformed: true))
                .transform(const LineSplitter())
                .forEach((line) {
                  onLine('编码', line);
                }),
          );
          final encodeExit = watch(encoder, '编码');
          if (stageFailure != null) throw StateError(stageFailure!);
          await Future.wait([
            pipe(
              decoder.stdout.map((bytes) {
                decodedBytes += bytes.length;
                return bytes;
              }),
              neural.stdin,
            ),
            pipe(
              neural.stdout.map((bytes) {
                enhancedBytes += bytes.length;
                return bytes;
              }),
              encoder.stdin,
            ),
            decodeExit,
            neuralExit,
            encodeExit,
          ]);
          await Future.wait(drains);
        }
      } finally {
        _killProcesses();
        await Future.wait(_processes.map((process) => process.exitCode));
        await Future.wait(drains);
      }
      _checkCancelled();
      if (stageFailure != null) throw StateError(stageFailure!);
      final frameBytes = width * height * 4;
      final outputFrameBytes = frameBytes * scale * scale;
      final frames = decodedBytes ~/ frameBytes;
      if (frames == 0 ||
          decodedBytes % frameBytes != 0 ||
          (!usesNativePipe && enhancedBytes != frames * outputFrameBytes) ||
          !decodedFinished ||
          !encodedFinished ||
          decodedFrames != frames ||
          completedFrames != frames ||
          encodedFrames != frames) {
        throw StateError(
          '增强输出不完整：输入 $frames 帧，增强 $completedFrames 帧，编码 $encodedFrames 帧',
        );
      }
      status = '正在保存结果…';
      _notify();
      final saved = await _probe(ffprobe.path, partial.path);
      final outputVideos = (saved['streams'] as List).where(
        (s) => s['codec_type'] == 'video',
      );
      if (outputVideos.isEmpty ||
          outputVideos.first['width'] != width * scale ||
          outputVideos.first['height'] != height * scale ||
          await partial.length() == 0) {
        throw StateError('编码结果缺失或尺寸不符');
      }
      _checkCancelled();
      partial = await partial.rename(
        '${jobDirectory.path}${Platform.pathSeparator}enhanced.mkv',
      );
      _checkCancelled();
      outputPath = partial.path;
      try {
        await File(
          '${jobDirectory.path}${Platform.pathSeparator}source.json',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'source': source.path,
            'output': outputPath,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'executable': executable.path,
            'intensity': intensity,
            'scale': scale,
            'frames': frames,
            'frameRate': rate,
            'transport': usesNativePipe ? 'windows-native' : 'dart-stream',
            'elapsedSeconds': stopwatch.elapsedMilliseconds / 1000,
          }),
        );
      } on FileSystemException catch (exception) {
        _appendLog('来源信息保存失败：$exception');
      }
      progress = 1;
      status = '增强完成，共 $frames 帧，用时 ${stopwatch.elapsed.inSeconds} 秒';
      return outputPath;
    } on _DlssCancelled {
      status = '已取消';
      return null;
    } catch (exception) {
      if (_cancelled) {
        status = '已取消';
      } else {
        error = exception.toString();
        status = '增强失败';
        _appendLog(error!);
      }
      return null;
    } finally {
      _killProcesses();
      await Future.wait(_processes.map((process) => process.exitCode));
      _processes.clear();
      if (outputPath == null && partial != null) {
        try {
          if (await partial.exists()) await partial.delete();
          // Only the empty directory created by this job is removed.
          if (jobDirectory != null) await jobDirectory.delete();
        } on FileSystemException catch (exception) {
          _appendLog('临时文件清理失败：$exception');
        }
      }
      running = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

class _DlssCancelled implements Exception {
  const _DlssCancelled();
}
