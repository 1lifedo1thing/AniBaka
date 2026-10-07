import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';

/// Anime4K 着色器管线，基于 Anime4K v4 着色器集合
class Anime4K {
  Anime4K._();

  static const _assetRoot = 'assets/anime4k';
  static Directory? _cachedDirectory;
  static final Map<String, Future<File>> _stagedFiles = {};

  static bool get isMobilePlatform =>
      Platform.isAndroid || Platform.isIOS || Instances.isTV;

  static const _clamp = 'Anime4K_Clamp_Highlights.glsl';
  static const _restoreM = 'Anime4K_Restore_CNN_M.glsl';
  static const _restoreVL = 'Anime4K_Restore_CNN_VL.glsl';
  static const _restoreSoftM = 'Anime4K_Restore_CNN_Soft_M.glsl';
  static const _restoreSoftVL = 'Anime4K_Restore_CNN_Soft_VL.glsl';
  static const _upscaleS = 'Anime4K_Upscale_CNN_x2_S.glsl';
  static const _upscaleM = 'Anime4K_Upscale_CNN_x2_M.glsl';
  static const _upscaleVL = 'Anime4K_Upscale_CNN_x2_VL.glsl';
  static const _downX2 = 'Anime4K_AutoDownscalePre_x2.glsl';
  static const _downX4 = 'Anime4K_AutoDownscalePre_x4.glsl';
  static const _anibakaClear = 'AniBaka_Clear_v1.glsl';

  static List<String> pipelineFiles(
    VideoEnhancementMode pipeline, {
    bool? mobile,
  }) {
    final useMobile = mobile ?? isMobilePlatform;
    return switch (pipeline) {
      VideoEnhancementMode.off => const <String>[],
      VideoEnhancementMode.low =>
        useMobile
            ? const [_clamp, _anibakaClear, _restoreM, _upscaleS]
            : const [
                _clamp,
                _anibakaClear,
                _restoreSoftM,
                _upscaleM,
                _downX2,
                _downX4,
                _upscaleS,
              ],
      VideoEnhancementMode.medium =>
        useMobile
            ? const [_clamp, _anibakaClear, _restoreM, _upscaleM]
            : const [
                _clamp,
                _anibakaClear,
                _restoreM,
                _upscaleM,
                _downX2,
                _downX4,
                _upscaleS,
              ],
      VideoEnhancementMode.high =>
        useMobile
            ? const [
                _clamp,
                _anibakaClear,
                _restoreM,
                _upscaleM,
                _downX2,
                _downX4,
                _upscaleS,
              ]
            : const [
                _clamp,
                _anibakaClear,
                _restoreSoftVL,
                _upscaleVL,
                _downX2,
                _downX4,
                _upscaleM,
              ],
      VideoEnhancementMode.ultra =>
        useMobile
            ? const [
                _clamp,
                _anibakaClear,
                _restoreM,
                _upscaleM,
                _downX2,
                _downX4,
                _restoreSoftM,
                _upscaleS,
              ]
            : const [
                _clamp,
                _anibakaClear,
                _restoreVL,
                _upscaleVL,
                _restoreM,
                _downX2,
                _downX4,
                _upscaleM,
              ],
    };
  }

  static Future<String> shaderPath(
    VideoEnhancementMode pipeline, {
    bool? mobile,
  }) async {
    final files = pipelineFiles(pipeline, mobile: mobile);
    if (files.isEmpty) return '';
    final dir = _cachedDirectory ??= await _shaderDirectory();
    final sep = Platform.pathSeparator;
    final staged = <String>[];

    for (final name in files) {
      final filePath = '${dir.path}$sep$name';
      // Check bundled bytes once per process, including after app upgrades.
      // Share pending writes so simultaneous players cannot read a partial file.
      final pending = _stagedFiles.putIfAbsent(
        filePath,
        () => _stageAsset(dir, name),
      );
      try {
        await pending;
      } catch (_) {
        if (identical(_stagedFiles[filePath], pending)) {
          _stagedFiles.remove(filePath);
        }
        rethrow;
      }
      staged.add(filePath);
    }
    return staged.join(Platform.isWindows ? ';' : ':');
  }

  static Future<File> _stageAsset(Directory directory, String name) async {
    final data = await rootBundle.load('$_assetRoot/$name');
    return _stageBytes(
      directory,
      name,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  static Future<Directory> _shaderDirectory() async {
    try {
      final base = await getApplicationSupportDirectory();
      final sep = Platform.pathSeparator;
      final dir = Directory('${base.path}${sep}shaders${sep}video_enhancement');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      final sep = Platform.pathSeparator;
      final dir = Directory(
        '${Directory.systemTemp.path}${sep}anibaka-shaders${sep}video_enhancement',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
  }

  @visibleForTesting
  static Future<File> stageBytesForTest(
    Directory directory,
    String name,
    List<int> bytes,
  ) => _stageBytes(directory, name, bytes);

  static Future<File> _stageBytes(
    Directory directory,
    String name,
    List<int> bytes,
  ) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    if (!await file.exists() || !listEquals(await file.readAsBytes(), bytes)) {
      await file.writeAsBytes(bytes, flush: true);
    }
    return file;
  }
}
