import 'package:baka/models/playback_request.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/models/play_history.dart';
import 'package:baka/services/account/bangumi_session.dart';

/// 播放历史同步服务
late HistoryRepository historyRepository;

class HistoryRepository {
  HistoryRepository(this.session, this.bangumi);

  final AccountSession session;
  final BangumiSession bangumi;

  static const _historyKey = 'history';
  static const _resumeKey = 'resume';
  static const _maxHistoryCount = 50;
  static const _minPositionToSaveMs = 10000;
  static const _completionThreshold = 0.95;
  static const _platform = 'app';

  final Map<String, List<Map<String, dynamic>>> _memory = {};

  String _localKey(Map record) {
    final bgm = toInt(record['bgmId']);
    final ep = toInt(record['index']);
    final video = (bgm != null && bgm > 0) ? 'bgm_$bgm' : 'id_${record['id']}';
    return '$video::ep_$ep';
  }

  String _remoteKey(PlayHistory r) {
    final bgm = r.bgmId;
    final ep = r.episodeId;
    final video = (bgm != null && bgm > 0) ? 'bgm_$bgm' : 'id_${r.videoId}';
    final normalizedEp = ep == null ? null : (ep > 0 ? ep - 1 : 0);
    return '$video::ep_$normalizedEp';
  }

  List<Map<String, dynamic>> _readList(String key) {
    final cached = _memory[key];
    if (cached != null) return cached;
    if (!Hive.isBoxOpen(AppStorage.playHistoryBoxName)) return const [];
    final stored = AppStorage.playHistoryBox.get(key);
    if (stored is! List) return const [];
    final records = <Map<String, dynamic>>[];
    for (var i = 0; i < stored.length; i++) {
      final item = stored[i];
      if (item is Map<String, dynamic>) {
        records.add(item);
      } else if (item is Map) {
        records.add(item.cast<String, dynamic>());
      }
    }
    return _memory[key] = records;
  }

  bool _sameAnime(Map left, Map right, {int? bgmId}) {
    final leftBgmId = bgmId ?? toInt(left['bgmId']);
    final rightBgmId = toInt(right['bgmId']);
    if (leftBgmId != null &&
        leftBgmId > 0 &&
        rightBgmId != null &&
        rightBgmId > 0) {
      return leftBgmId == rightBgmId;
    }
    final leftId = left['id']?.toString();
    final rightId = right['id']?.toString();
    if (leftId != null && leftId.isNotEmpty && leftId == rightId) {
      return true;
    }
    final leftTitle = left['title']?.toString() ?? '';
    final rightTitle = right['title']?.toString() ?? '';
    return leftTitle.isNotEmpty && leftTitle == rightTitle;
  }

  Map<String, dynamic> _fromRemote(PlayHistory r) {
    final bgmId = r.bgmId;
    final ep = r.episodeId;
    return {
      'id': r.videoId.toString(),
      'title': r.videoTitle,
      'content': r.videoCover ?? '',
      'index': ep == null ? null : (ep > 0 ? ep - 1 : 0),
      'position': r.playProgress * 1000,
      'duration': r.videoDuration * 1000,
      'watchTime':
          r.updatedAt?.millisecondsSinceEpoch ??
          DateTime.now().millisecondsSinceEpoch,
      'url': 1,
      if (bgmId != null && bgmId > 0) 'bgmId': bgmId,
    };
  }

  PlayHistory? _toRemote(Map local) {
    final bgmId = toInt(local['bgmId']);
    final validBgm = (bgmId != null && bgmId > 0) ? bgmId : null;
    final videoId = validBgm ?? toInt(local['id']);
    if (videoId == null) return null;

    final episodeIndex = toInt(local['index']);
    final cover = resolveCoverImage(local);
    final position = local['position'] as num? ?? 0;
    final duration = local['duration'] as num? ?? 0;

    return PlayHistory(
      videoId: videoId,
      videoTitle: local['title']?.toString() ?? '未知标题',
      videoCover: (cover == null || cover.isEmpty) ? null : cover,
      videoDuration: (duration / 1000).round(),
      playProgress: (position / 1000).round(),
      episodeId: episodeIndex != null ? episodeIndex + 1 : null,
      episodeTitle: episodeIndex != null ? '第${episodeIndex + 1}集' : null,
      videoType: 2,
      platform: _platform,
      bgmId: validBgm,
    );
  }

  Future<void> _write(String key, List<Map<String, dynamic>> list) {
    _memory[key] = list;
    return AppStorage.playHistoryBox.put(key, list);
  }

  List<Map<String, dynamic>> getHistoryList() => _readList(_historyKey);

  ({int episodeIndex, int lineIndex})? _findResumeSelection(
    PlaybackRequest request,
    Iterable<Map> records,
    int? bgmId,
  ) {
    for (final record in records) {
      if (!_sameAnime(request.metadata, record, bgmId: bgmId)) continue;
      final episodeIndex = toInt(record['index']);
      if (episodeIndex == null || episodeIndex < 0) continue;
      final source = request.source;
      final rememberedSource = record['source']?.toString() ?? '';
      final sameSource =
          source.isEmpty ||
          rememberedSource.isEmpty ||
          source == rememberedSource;
      final lineIndex = sameSource ? (toInt(record['url']) ?? 1) : 1;
      return (
        episodeIndex: episodeIndex,
        lineIndex: lineIndex > 0 ? lineIndex : 1,
      );
    }
    return null;
  }

  ({int episodeIndex, int lineIndex})? getResumeSelection(
    PlaybackRequest request, {
    int? bgmId,
  }) =>
      _findResumeSelection(request, _readList(_resumeKey), bgmId) ??
      _findResumeSelection(request, _readList(_historyKey), bgmId);

  Future<void> rememberEpisode({
    required PlaybackRequest request,
    required int episodeIndex,
    required int urlIndex,
    int? bgmId,
  }) async {
    if (episodeIndex < 0 || !Hive.isBoxOpen(AppStorage.playHistoryBoxName)) {
      return;
    }
    final record = <String, dynamic>{
      'id': request.metadata['id'],
      'title': request.metadata['title'],
      'bgmId': bgmId ?? request.metadata['bgmId'],
      'source': request.source,
      'index': episodeIndex,
      'url': urlIndex > 0 ? urlIndex : 1,
      'watchTime': DateTime.now().millisecondsSinceEpoch,
    };

    final list = _readList(_resumeKey);
    final next = <Map<String, dynamic>>[record];
    for (var i = 0; i < list.length; i++) {
      final item = list[i];
      if (_sameAnime(record, item)) continue;
      next.add(item);
      if (next.length >= _maxHistoryCount) break;
    }
    await _write(_resumeKey, next);
  }

  Future<void> syncRemoteToLocal() async {
    try {
      final response = await AniBakaApi.getPlayHistory(
        pageSize: _maxHistoryCount,
      );
      if (response == null || response.isEmpty) return;

      final list = getHistoryList();
      final map = <String, Map<String, dynamic>>{};
      for (var i = 0; i < list.length; i++) {
        final item = list[i];
        map.putIfAbsent(_localKey(item), () => item);
      }

      for (final remote in response) {
        final key = _remoteKey(remote);
        final local = map[key];
        final remoteTime = remote.updatedAt?.millisecondsSinceEpoch ?? 0;
        final localTime = (local?['watchTime'] as int?) ?? 0;
        if (local == null || remoteTime >= localTime) {
          final next = _fromRemote(remote);
          if (local != null) next['url'] = local['url'] ?? 1;
          map[key] = next;
        }
      }

      final ordered = map.values.toList(growable: false)
        ..sort(
          (a, b) => ((b['watchTime'] as int?) ?? 0).compareTo(
            (a['watchTime'] as int?) ?? 0,
          ),
        );
      final finalHistory = ordered.length > _maxHistoryCount
          ? ordered.sublist(0, _maxHistoryCount)
          : ordered;
      await _write(_historyKey, finalHistory);
    } catch (e) {
      debugPrint('同步远程历史失败: $e');
    }
  }

  Future<void> saveHistory({
    required PlaybackRequest request,
    required int episodeIndex,
    required int positionMs,
    required int durationMs,
    required int urlIndex,
    String? cover,
    int? bgmId,
  }) async {
    try {
      if (durationMs <= 0 || positionMs <= _minPositionToSaveMs) return;

      final record = <String, dynamic>{
        'id': request.metadata['id'],
        'title': request.metadata['title'],
        'content': request.metadata['content'],
        'image': request.metadata['image'],
        'bgmImageUrl': cover ?? request.metadata['bgmImageUrl'],
        'bgmId': bgmId ?? request.metadata['bgmId'],
        'source': request.source,
        'seriesUrl': request.metadata['seriesUrl'],
        'sourceUrl': request.metadata['sourceUrl'],
        'sourceDisplayName': request.metadata['sourceDisplayName'],
        'tag': request.metadata['tag'],
        'score': request.metadata['score'],
        'info': request.metadata['info'],
        'index': episodeIndex,
        'position': positionMs,
        'duration': durationMs,
        'watchTime': DateTime.now().millisecondsSinceEpoch,
        'url': urlIndex,
        'isFinished': positionMs / durationMs >= _completionThreshold,
      };

      final key = _localKey(record);
      final list = _readList(_historyKey);
      final next = <Map<String, dynamic>>[record];
      for (var i = 0; i < list.length; i++) {
        final item = list[i];
        if (_localKey(item) == key) continue;
        next.add(item);
        if (next.length >= _maxHistoryCount) break;
      }
      await _write(_historyKey, next);

      final remote = _toRemote(record);
      if (remote != null && session.token.isNotEmpty) {
        unawaited(
          AniBakaApi.savePlayHistory(remote).catchError((Object error) {
            // Local history is already saved; cloud sync is best effort here.
            debugPrint('上传播放历史失败: $error');
            return null;
          }),
        );
      }

      final subjectId = toInt(record['bgmId']);
      if (record['isFinished'] == true &&
          subjectId != null &&
          bangumi.isConnected &&
          bangumi.autoMarkEpisode) {
        unawaited(
          bangumi
              .markEpisodeWatched(
                subjectId: subjectId,
                watched: episodeIndex + 1,
              )
              .catchError((Object error, StackTrace stackTrace) {
                debugPrint('更新 Bangumi 集数失败: $error');
              }),
        );
      }
    } catch (e) {
      debugPrint('保存历史记录错误: $e');
    }
  }

  static bool isEpisodeWatched(String videoId, int episodeIndex) =>
      readProgress('${videoId}_${episodeIndex}_1').inSeconds > 30;

  static Duration readProgress(String key) => Duration(
    milliseconds:
        AppStorage.videoProgressBox.get(key)?['positionMs'] as int? ?? 0,
  );

  Future<void> saveProgress(String key, Duration position) =>
      AppStorage.videoProgressBox.put(key, {
        'positionMs': position.inMilliseconds,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
      });

  Future<void> clearHistory() async {
    await Future.wait([
      _write(_historyKey, const []),
      _write(_resumeKey, const []),
    ]);
  }
}
