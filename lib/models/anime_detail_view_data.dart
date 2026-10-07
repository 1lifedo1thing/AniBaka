import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';
import 'package:baka/utils/bgm_utils.dart';

class AnimeDetailViewData {
  const AnimeDetailViewData({
    required this.title,
    required this.bgmTitle,
    required this.alias,
    required this.summary,
    required this.coverUrl,
    required this.backgroundUrl,
    required this.logoUrl,
    required this.tags,
    required this.genres,
    required this.infobox,
    required this.scoreCount,
    required this.scoreDistribution,
    required this.backdrops,
    required this.posters,
    required this.status,
    required this.collectCount,
    required this.doingCount,
    required this.wishCount,
    this.score,
    this.rank,
    this.airDate,
    this.episodeCount,
    this.imdbId,
    this.tmdbId,
    this.tvdbId,
    this.bgmId,
  });

  final String title;
  final String bgmTitle;
  final String alias;
  final String summary;
  final String coverUrl;
  final String backgroundUrl;
  final String logoUrl;
  final List<String> tags;
  final List<String> genres;
  final List<Map<String, dynamic>> infobox;
  final double? score;
  final int scoreCount;

  /// Bangumi 1–10 分人数分布，下标 0 = 1 分。全 0 表示无数据。
  final List<int> scoreDistribution;
  final int? rank;
  final List<String> backdrops;
  final List<String> posters;
  final String status;
  final String? airDate;
  final int? episodeCount;
  final int collectCount;
  final int doingCount;
  final int wishCount;
  final String? imdbId;
  final String? tmdbId;
  final String? tvdbId;
  final int? bgmId;

  bool get hasScoreDistribution =>
      scoreDistribution.length == 10 && scoreDistribution.any((c) => c > 0);

  factory AnimeDetailViewData.from({
    required Map source,
    required BgmInfo bgmInfo,
    Map<String, dynamic>? anibaka,
    Map<String, dynamic>? bgm,
  }) {
    final titles = anibaka?['title'] as Map<String, dynamic>?;
    final cnTitle = trimmed(titles?['cn']);
    final nativeTitle = trimmed(titles?['native']);
    final enTitle = trimmed(titles?['en']);
    final fallbackTitle =
        trimmed(bgm?['name_cn']) ??
        trimmed(bgm?['name']) ??
        trimmed(source['title']) ??
        '番剧详情';
    final title = cnTitle ?? nativeTitle ?? enTitle ?? fallbackTitle;

    final alias = nativeTitle != null && nativeTitle != title
        ? nativeTitle
        : (enTitle != null && enTitle != title ? enTitle : '');

    final images = anibaka?['images'] as Map<String, dynamic>?;
    final posters = _imageUrls(images?['posters']);
    final backdrops = _imageUrls(images?['backdrops']);
    final logoUrl = resolveLogoUrl(anibaka);
    final cover =
        resolveCoverImage(source, bgmInfo: bgmInfo) ??
        (posters.isNotEmpty ? posters.first : '');

    final rawGenres = anibaka?['genres'];
    final genres = rawGenres is List
        ? rawGenres.cast<String>()
        : const <String>[];

    final rawTags = <String>{...genres};
    if (bgm?['tags'] is List) {
      for (final t in bgm!['tags']) {
        if (t is Map && t['name'] != null) {
          final name = t['name'].toString().trim();
          if (name.isNotEmpty) rawTags.add(name);
        }
      }
    }
    if (source['tag'] != null) {
      for (final s in source['tag'].toString().split(RegExp(r'\s+'))) {
        final st = s.trim();
        if (st.isNotEmpty) rawTags.add(st);
      }
    }

    final ratings = anibaka?['ratings'] as Map<String, dynamic>?;
    final anibakaRating = ratings?['bgm'] as Map<String, dynamic>?;
    final bgmRating = bgm?['rating'] as Map<String, dynamic>?;
    final score =
        toDouble(anibakaRating?['score']) ??
        BgmUtils.extractScore(bgm?['rating']) ??
        bgmInfo.score;
    final scoreCount =
        toInt(anibakaRating?['total']) ?? toInt(bgmRating?['total']) ?? 0;
    final rank = toInt(anibakaRating?['rank']) ?? toInt(bgmRating?['rank']);

    final scoreCountMap = bgmRating?['count'] as Map?;
    final scoreDistribution = _parseScoreDistribution(scoreCountMap);

    final ids = anibaka?['ids'] as Map<String, dynamic>?;
    final imdbId = trimmed(ids?['imdb_id']);
    final tmdbId = trimmed(ids?['tmdb_id']);
    final tvdbId = trimmed(ids?['tvdb_id']);
    final bgmId =
        toInt(ids?['bgm_id']) ?? toInt(bgm?['id']) ?? toInt(source['bgmId']);
    final bgmTitle = trimmed(bgm?['name_cn']) ?? trimmed(bgm?['name']) ?? title;
    final collection = bgm?['collection'] as Map<String, dynamic>?;

    return AnimeDetailViewData(
      title: title,
      bgmTitle: bgmTitle,
      alias: alias,
      summary:
          trimmed(anibaka?['overview']) ??
          trimmed(bgm?['summary']) ??
          trimmed(source['content']) ??
          '暂无简介',
      coverUrl: cover,
      backgroundUrl: backdrops.isNotEmpty ? backdrops.first : cover,
      logoUrl: logoUrl,
      tags: rawTags.toList(growable: false),
      genres: genres,
      infobox: _buildInfobox(anibaka, bgm, enTitle, title),
      score: score,
      scoreCount: scoreCount,
      scoreDistribution: scoreDistribution,
      rank: rank,
      backdrops: backdrops,
      posters: posters,
      status: trimmed(anibaka?['status']) ?? '',
      airDate: trimmed(bgm?['date']) ?? trimmed(anibaka?['date']),
      episodeCount:
          toInt(anibaka?['episodes']) ??
          toInt(bgm?['total_episodes']) ??
          toInt(bgm?['eps']),
      collectCount: toInt(collection?['collect']) ?? 0,
      doingCount: toInt(collection?['doing']) ?? 0,
      wishCount: toInt(collection?['wish']) ?? 0,
      imdbId: imdbId,
      tmdbId: tmdbId,
      tvdbId: tvdbId,
      bgmId: bgmId,
    );
  }

  /// Picks the backdrop supplied by AniBaka's TMDB image source.
  ///
  /// Prefer a Chinese backdrop when the API provides multiple TMDB variants.
  static String? pickTmdbBackdrop(Map<String, dynamic>? detail) {
    final images = detail?['images'];
    if (images is! Map) return null;
    final candidates = images['backdrops'];
    if (candidates is! List) return null;
    Map<String, dynamic>? fallback;

    for (final candidate in candidates.cast<Map<String, dynamic>>()) {
      if (trimmed(candidate['source'])?.toLowerCase() != 'tmdb') continue;
      fallback ??= candidate;
      if (trimmed(candidate['lang'])?.toLowerCase() == 'zh') {
        return trimmed(candidate['url']) ?? trimmed(candidate['thumbnail']);
      }
    }

    return trimmed(fallback?['url']) ?? trimmed(fallback?['thumbnail']);
  }

  static List<int> _parseScoreDistribution(Map? countMap) {
    if (countMap == null || countMap.isEmpty) {
      return const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    }
    return List<int>.generate(10, (i) {
      final key = '${i + 1}';
      return toInt(countMap[key]) ?? 0;
    }, growable: false);
  }

  /// 取条目 logo：优先 `images.logos` 里的中文 logo，其次第一个 logo，最后
  /// 顶层的 `logoUrl` / `logo`（播放数据里由 [resolveLogoUrl] 回填）。
  static String resolveLogoUrl(Map<String, dynamic>? detail) {
    if (detail == null) return '';
    final rawLogos = (detail['images'] as Map?)?['logos'];
    if (rawLogos is List && rawLogos.isNotEmpty) {
      String? zhLogo;
      String? firstLogo;
      for (final item in rawLogos) {
        if (item is! Map) continue;
        final url = trimmed(item['url']) ?? trimmed(item['thumbnail']);
        if (url == null) continue;
        firstLogo ??= url;
        final lang = item['lang']?.toString().toLowerCase();
        if (lang != null && (lang.startsWith('zh') || lang == 'cn')) {
          zhLogo = url;
          break;
        }
      }
      final chosen = zhLogo ?? firstLogo;
      if (chosen != null && chosen.isNotEmpty) return chosen;
    }

    return trimmed(detail['logoUrl']) ?? trimmed(detail['logo']) ?? '';
  }

  /// AniBaka 的 `posters / backdrops` 是 `{url, thumbnail, source, lang?}` 数组。
  static List<String> _imageUrls(dynamic value) {
    if (value is! List) return const [];
    final urls = <String>[];
    final seen = <String>{};
    for (final item in value) {
      if (item is! Map) continue;
      final url = trimmed(item['url']) ?? trimmed(item['thumbnail']);
      if (url != null && seen.add(url)) urls.add(url);
    }
    return urls;
  }

  static List<Map<String, dynamic>> _buildInfobox(
    Map<String, dynamic>? anibaka,
    Map<String, dynamic>? bgm,
    String? englishTitle,
    String title,
  ) {
    final result = <Map<String, dynamic>>[];
    final keys = <String>{};

    void add(String key, dynamic value) {
      final text = trimmed(value);
      if (text != null && keys.add(key)) {
        result.add({'key': key, 'value': text});
      }
    }

    add('状态', anibaka?['status']);
    add('播出日期', anibaka?['date']);
    final episodeCount = toInt(anibaka?['episodes']);
    if (episodeCount != null && episodeCount > 0) add('集数', '$episodeCount 话');
    final ratings = anibaka?['ratings'] as Map<String, dynamic>?;
    final rating = ratings?['bgm'] as Map<String, dynamic>?;
    final rank = toInt(rating?['rank']);
    if (rank != null && rank > 0) add('排名', '#$rank');
    if (englishTitle != null &&
        englishTitle.isNotEmpty &&
        englishTitle != title) {
      add('英文名', englishTitle);
    }

    if (bgm?['infobox'] is List) {
      for (final item in bgm!['infobox']) {
        if (item is Map<String, dynamic>) {
          final key = trimmed(item['key']);
          if (key != null && keys.add(key)) {
            result.add(item);
          }
        }
      }
    }
    return result;
  }
}
