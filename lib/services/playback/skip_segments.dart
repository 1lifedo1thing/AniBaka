import 'dart:convert';

import 'package:baka/api/api_config.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/skip_segment.dart';

class SkipSegmentsService {
  static const _storageKey = 'player_skip_segments_v1';
  static const _suggestionsKey = 'player_skip_suggestions_v1';

  bool hasAnsweredSuggestion(String key) =>
      (Instances.sp.getStringList(_suggestionsKey) ?? const []).contains(key);

  Future<void> rememberSuggestion(String key) async {
    final keys = Instances.sp.getStringList(_suggestionsKey) ?? <String>[];
    keys.remove(key);
    keys.add(key);
    await Instances.sp.setStringList(
      _suggestionsKey,
      keys.length > 1000 ? keys.sublist(keys.length - 1000) : keys,
    );
  }

  Map<String, dynamic> _read() {
    try {
      return jsonDecode(Instances.sp.getString(_storageKey) ?? '{}')
          as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  SkipContext restoreBinding(SkipContext context) {
    final saved = _read()[context.sourceKey];
    if (saved is Map && saved['bgm_id'] is int && saved['episode_id'] is int) {
      return context.bind(saved['bgm_id'] as int, saved['episode_id'] as int);
    }
    return context;
  }

  Future<void> bind(SkipContext context) async {
    final data = _read();
    data[context.sourceKey] = {
      'bgm_id': context.subjectId,
      'episode_id': context.episodeId,
    };
    await _write(data);
  }

  Future<void> _write(Map<String, dynamic> data) async {
    // Keep a bounded set of personal corrections, not a growing history log.
    while (data.length > 1000) {
      data.remove(data.keys.first);
    }
    await Instances.sp.setString(_storageKey, jsonEncode(data));
  }

  Future<void> saveLocal(SkipContext context, SkipSegment segment) async {
    final data = _read();
    final local = Map<String, dynamic>.from(
      data[context.localKey] as Map? ?? {},
    );
    local[segment.type] = segment.toJson();
    local.remove('disabled_${segment.type}');
    data.remove(context.localKey);
    data[context.localKey] = local;
    await _write(data);
  }

  Future<void> disable(SkipContext context, String type, bool disabled) async {
    final data = _read();
    final local = Map<String, dynamic>.from(
      data[context.localKey] as Map? ?? {},
    );
    if (disabled) {
      local['disabled_$type'] = true;
    } else {
      local.remove('disabled_$type');
    }
    data[context.localKey] = local;
    await _write(data);
  }

  Set<String> disabledTypes(SkipContext context) {
    final local = _read()[context.localKey] as Map? ?? {};
    return {
      for (final type in ['op', 'ed'])
        if (local['disabled_$type'] == true) type,
    };
  }

  List<SkipSegment> mergeLocal(
    SkipContext context,
    int duration,
    List<SkipSegment> remote,
  ) {
    final local = _read()[context.localKey] as Map? ?? {};
    final result = <SkipSegment>[];
    for (final type in ['op', 'ed']) {
      final value = local[type];
      if (local['disabled_$type'] == true) continue;
      if (value is Map) {
        final segment = SkipSegment.fromJson(Map<String, dynamic>.from(value));
        if (segment.fits(duration)) {
          result.add(segment);
          continue;
        }
        // A saved correction for another cut must not fall back to public data.
        continue;
      }
      result.addAll(remote.where((s) => s.type == type && s.fits(duration)));
    }
    return List.unmodifiable(result);
  }

  Future<SkipData> load(SkipContext context, int duration) async {
    var remote = <SkipSegment>[];
    var message = context.bound ? '暂无匹配区间，可手动标注' : '绑定 Bangumi 剧集后可查询和共享';
    if (context.bound) {
      try {
        final uri = Uri.parse('${ApiConfig.host}/api/v1/skip-segments').replace(
          queryParameters: context
              .toJson(duration)
              .map((key, value) => MapEntry(key, '$value')),
        );
        final json = await apiTransport.getData<Map<String, dynamic>>(
          uri.toString(),
          timeout: const Duration(seconds: 8),
          notifyOnError: false,
        );
        remote = [
          for (final value in json['segments'] as List? ?? [])
            SkipSegment.fromJson(Map<String, dynamic>.from(value as Map)),
        ];
        if (json['upstream_unavailable'] == true) {
          message = '公共数据暂不可用，仍可使用已保存的标注';
        }
        if (remote.isNotEmpty) message = '已查询当前剧集；未确认区间仅支持手动跳过';
      } catch (_) {
        message = '服务器暂不支持或查询失败，仍可在本机标注';
      }
    }
    return SkipData(
      context: context,
      segments: mergeLocal(context, duration, remote),
      message: message,
    );
  }

  Future<void> submit(SkipContext context, SkipSegment segment) async {
    if (!context.bound) throw const FormatException('请先绑定 Bangumi 剧集');
    await apiTransport.postData<Map<String, dynamic>>(
      '${ApiConfig.host}/api/v1/skip-segments',
      {
        ...context.toJson(segment.durationMs),
        'type': segment.type,
        'start_ms': segment.startMs,
        'end_ms': segment.endMs,
      },
      notifyOnError: false,
    );
  }

  Future<void> feedback(
    SkipContext context,
    SkipSegment segment,
    bool accurate,
  ) async {
    await apiTransport.putData<Map<String, dynamic>>(
      '${ApiConfig.host}/api/v1/skip-segments/${Uri.encodeComponent(segment.id)}/feedback',
      {...context.toJson(segment.durationMs), 'accurate': accurate},
      notifyOnError: false,
    );
  }
}
