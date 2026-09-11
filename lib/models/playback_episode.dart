import 'package:flutter/foundation.dart';

@immutable
class PlaybackEpisode {
  const PlaybackEpisode({required this.title, required this.lines});

  static const separator = '\$';

  final String title;
  final List<String> lines;

  int get lineCount => lines.length;

  String? lineAt(int oneBasedIndex) {
    final index = oneBasedIndex - 1;
    return index >= 0 && index < lines.length ? lines[index] : null;
  }

  String serialize() =>
      lines.isEmpty ? title : '$title$separator${lines.join(separator)}';

  static PlaybackEpisode? parse(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    final titleEnd = trimmed.indexOf(separator);
    if (titleEnd < 0) {
      return PlaybackEpisode(title: trimmed, lines: const []);
    }

    final title = trimmed.substring(0, titleEnd).trim();
    final parts = trimmed.substring(titleEnd + 1).split(separator);
    final lines = parts
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList(growable: false);

    return PlaybackEpisode(title: title, lines: lines);
  }
}

class PlaybackEpisodeCatalog {
  PlaybackEpisodeCatalog._();

  /// 从 Map 数据中提取已解析的剧集列表。
  static List<PlaybackEpisode> episodesOf(
    Map data, {
    bool mergeDuplicateTitles = false,
  }) {
    final rawList = data['videoList'];
    if (rawList is List<PlaybackEpisode>) return rawList;
    return parse(
      rawEpisodesOf(data),
      mergeDuplicateTitles: mergeDuplicateTitles,
    );
  }

  /// 提取未解析的序列化剧集字符串列表。
  static List<String> rawEpisodesOf(Map data) {
    final rawList = data['videoList'];
    if (rawList is List) {
      final out = <String>[];
      for (final item in rawList) {
        if (item is PlaybackEpisode) {
          out.add(item.serialize());
        } else if (item is String && item.trim().isNotEmpty) {
          out.add(item.trim());
        }
      }
      if (out.isNotEmpty) return out;
    }

    final raw = data['videos'];
    if (raw is! String || raw.isEmpty) return const [];
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  /// 获取指定下标的剧集。
  static PlaybackEpisode? episodeAt(Map data, int index) {
    if (index < 0) return null;
    final raw = rawEpisodesOf(data);
    if (index >= raw.length) return null;
    return PlaybackEpisode.parse(raw[index]);
  }

  /// 计算剧集总数。
  static int countFrom(Map data) {
    final rawList = data['videoList'];
    if (rawList is List) {
      if (rawList is List<PlaybackEpisode>) return rawList.length;
      var count = 0;
      for (final item in rawList) {
        if (item is PlaybackEpisode || (item is String && item.trim().isNotEmpty)) {
          count++;
        }
      }
      if (count > 0) return count;
    }

    final raw = data['videos'];
    if (raw is String && raw.isNotEmpty) {
      return raw.split('\n').where((l) => l.trim().isNotEmpty).length;
    }
    return 0;
  }

  /// 解析序列化字符串集合为 [PlaybackEpisode] 列表。
  static List<PlaybackEpisode> parse(
    Iterable<String> values, {
    bool mergeDuplicateTitles = false,
  }) {
    if (!mergeDuplicateTitles) {
      final episodes = <PlaybackEpisode>[];
      for (final value in values) {
        final episode = PlaybackEpisode.parse(value);
        if (episode != null) episodes.add(episode);
      }
      return episodes;
    }

    final slotOf = <String, int>{};
    final episodes = <PlaybackEpisode>[];

    for (final value in values) {
      final episode = PlaybackEpisode.parse(value);
      if (episode == null) continue;

      final key = _mergeKey(episode.title);
      final slot = slotOf[key];
      if (slot == null) {
        slotOf[key] = episodes.length;
        episodes.add(episode);
      } else {
        final existing = episodes[slot];
        episodes[slot] = PlaybackEpisode(
          title: existing.title,
          lines: [...existing.lines, ...episode.lines],
        );
      }
    }

    return episodes;
  }

  static String _mergeKey(String title) {
    final trimmed = title.trim();
    final normalized = trimmed.replaceFirst(RegExp(r'^\d+[\s.、:：]*'), '').trim();
    return normalized.isEmpty ? trimmed : normalized;
  }

  /// 按搜索词和正倒序过滤剧集下标。
  static List<int> filterIndexes(
    List<PlaybackEpisode> episodes, {
    required bool ascending,
    String searchQuery = '',
  }) {
    final query = searchQuery.trim().toLowerCase();
    final result = <int>[];
    final last = episodes.length - 1;

    for (var n = 0; n <= last; n++) {
      final i = ascending ? n : last - n;
      if (query.isEmpty || episodes[i].title.toLowerCase().contains(query)) {
        result.add(i);
      }
    }
    return result;
  }
}
