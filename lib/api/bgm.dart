import 'package:flutter/foundation.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/title_matcher.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/core/api_transport.dart';

const String _bgmApiBase = 'https://bgm.anibaka.com';
const String _bgmNextBase = 'https://p1.anibaka.com';
const Duration _bgmCacheTtl = Duration(minutes: 5);

final _spaces = RegExp(r'\s+');

typedef BgmCommentPage = ({List<Map<String, dynamic>> comments, int total});

final _subjectCache = RequestCache<int, Map<String, dynamic>>(
  limit: 32,
  ttl: _bgmCacheTtl,
);
final _episodeCache = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 8,
  ttl: _bgmCacheTtl,
);
final _relatedCache = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 16,
  ttl: _bgmCacheTtl,
);
final _characterInfoCache = RequestCache<int, Map<String, dynamic>>(
  limit: 16,
  ttl: _bgmCacheTtl,
);
final _characterCommentsCache = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 8,
  ttl: _bgmCacheTtl,
);
final _subjectCommentsCache = RequestCache<String, BgmCommentPage>(
  limit: 4,
  ttl: _bgmCacheTtl,
);
final _episodeCommentsCache = RequestCache<int, List<Map<String, dynamic>>>(
  limit: 8,
  ttl: _bgmCacheTtl,
);
final _searchCache = RequestCache<String, List<BgmSubjectInfo>>(
  limit: 64,
  ttl: _bgmCacheTtl,
);

/// v0 条目原始响应（含 infobox / tags / rating.count / collection）。
Map<String, dynamic>? peekBgmSubject(int subjectId) =>
    _subjectCache.peek(subjectId);

Future<Map<String, dynamic>> getBgmSubject(int subjectId) => _subjectCache.get(
  subjectId,
  () => apiTransport.getMap('$_bgmApiBase/v0/subjects/$subjectId'),
);

Future<BgmSubjectInfo> _subjectInfo(int subjectId) async =>
    BgmSubjectInfo.fromJson(await getBgmSubject(subjectId));

Future<List<Map<String, dynamic>>> getBgmEpisodes(int subjectId) {
  return _episodeCache.get(subjectId, () async {
    final response = await apiTransport.getMap(
      '$_bgmApiBase/v0/episodes?subject_id=$subjectId&type=0&limit=200',
    );
    final episodes = BgmUtils.asMapList(response['data']);
    episodes.sort(
      (left, right) => (left['sort'] as num).compareTo(right['sort'] as num),
    );
    return episodes;
  });
}

/// 角色响应通常远大于条目本身，只由角色页按需读取，不驻留全局缓存。
Future<List<Map<String, dynamic>>> getBgmCharacters(int subjectId) async =>
    BgmUtils.asMapList(
      await apiTransport.getRawList(
        '$_bgmApiBase/v0/subjects/$subjectId/characters',
      ),
    );

Future<List<Map<String, dynamic>>> getBgmRelatedSubjects(int subjectId) =>
    _relatedCache.get(
      subjectId,
      () async => BgmUtils.asMapList(
        await apiTransport.getRawList(
          '$_bgmApiBase/v0/subjects/$subjectId/subjects',
        ),
      ),
    );

Future<List<Map<String, dynamic>>> getTrendingSubjects({
  int type = 2,
  int limit = 24,
  int offset = 0,
}) async {
  final response = await apiTransport.getMap(
    '$_bgmNextBase/p1/trending/subjects?type=$type&limit=$limit&offset=$offset',
  );
  return BgmUtils.asMapList(response['data']);
}

/// BGM 每日放送（一周更新表）。
///
/// 返回以星期为 key（1=周一 … 7=周日）的 Map，值为
/// `[{subject: {...}, watchers: n}]`，subject 与 trending 接口同构。
Future<Map<String, List<Map<String, dynamic>>>> getBgmCalendar() async {
  final data = await apiTransport.getMap('$_bgmNextBase/p1/calendar');
  return {
    for (final entry in data.entries)
      entry.key: BgmUtils.asMapList(entry.value),
  };
}

Future<BgmCommentPage> getBgmSubjectComments(
  int subjectId, {
  int limit = 20,
  int offset = 0,
}) {
  final cacheKey = '$subjectId:$limit:$offset';
  return _subjectCommentsCache.get(cacheKey, () async {
    final json = await apiTransport.getMap(
      '$_bgmNextBase/p1/subjects/$subjectId/comments?limit=$limit&offset=$offset',
    );
    return (
      comments: BgmUtils.asMapList(json['data']),
      total: (json['total'] as num).toInt(),
    );
  });
}

Future<List<Map<String, dynamic>>> getBgmEpisodeComments(int episodeId) =>
    _episodeCommentsCache.get(
      episodeId,
      () async => BgmUtils.asMapList(
        await apiTransport.getRawList(
          '$_bgmNextBase/p1/episodes/$episodeId/comments',
        ),
      ),
    );

Future<Map<String, dynamic>> getBgmCharacterInfo(int characterId) =>
    _characterInfoCache.get(
      characterId,
      () => apiTransport.getMap('$_bgmNextBase/p1/characters/$characterId'),
    );

Future<List<Map<String, dynamic>>> getBgmCharacterComments(int characterId) =>
    _characterCommentsCache.get(
      characterId,
      () async => BgmUtils.asMapList(
        await apiTransport.getRawList(
          '$_bgmNextBase/p1/characters/$characterId/comments',
        ),
      ),
    );

/// 通过标签搜索 BGM 动画
///
/// 使用 BGM v0 搜索 API (POST /v0/search/subjects)
/// [tags] BGM 标签列表（AND 关系）
/// [sort] 排序：rank(排名) / heat(热度) / score(评分) / match(相关)
Future<List<Map<String, dynamic>>> searchBgmByTag(
  List<String> tags, {
  int limit = 25,
  int offset = 0,
  String sort = 'rank',
  List<String>? airDate,
}) async {
  final filter = <String, dynamic>{
    'type': [2],
  };
  if (tags.isNotEmpty) filter['tag'] = tags;
  if (airDate != null && airDate.isNotEmpty) filter['air_date'] = airDate;

  final response = await apiTransport.postMap(
    '$_bgmApiBase/v0/search/subjects?limit=$limit&offset=$offset',
    {
      // Bangumi rejects an empty keyword. `*` keeps this a filter-only search.
      'keyword': '*',
      'sort': sort,
      'filter': filter,
    },
  );
  return BgmUtils.asMapList(response['data']);
}

const _scoreCacheDuration = Duration(days: 7);

/// 分数在 Hive 中持久化 7 天（读时间 TTL），避免列表反复按标题回源搜索。
final TtlCache _scoreCache = TtlCache(
  AppStorage.bgmCacheBox,
  ttl: _scoreCacheDuration,
);

Future<BgmInfo> resolveBgmFromData(Map data) async {
  final existing = BgmUtils.readFromData(data);
  if (existing.subjectId != null) return existing;

  final info = await _fetchScore(
    data['bgmId']?.toString() ?? '',
    data['title']?.toString() ?? '',
  );
  BgmUtils.writeToData(data, info);
  return info;
}

Future<List<BgmSubjectInfo>> searchBgmSubjects(String keyword) {
  final clean = keyword.replaceAll(_spaces, ' ').trim();
  if (BgmUtils.keepTitleUnits(clean).isEmpty) {
    return SynchronousFuture(const []);
  }
  return _search(clean);
}

/// 按主线剧集顺序查找评论接口所需的 BGM episode id。
Future<({int? episodeId, String name})?> resolveBgmEpisodeByIndex(
  int subjectId,
  int episodeIndex,
) async {
  if (subjectId <= 0 || episodeIndex < 0) return null;

  final rawEpisodes = await getBgmEpisodes(subjectId);
  if (episodeIndex >= rawEpisodes.length) return null;

  final episode = rawEpisodes[episodeIndex];
  return (
    episodeId: BgmUtils.toInt(episode['id']),
    name:
        BgmUtils.trimmed(episode['name_cn']) ??
        BgmUtils.trimmed(episode['name']) ??
        '',
  );
}

/// 解析条目标识：已知 bgmId 直接取条目，否则按标题搜索取最匹配的一条。
///
/// 搜索结果本身已含 `score / id / images`，无需再回源拉取整个条目。
Future<BgmSubjectInfo?> resolveBgmSubject({
  String bgmId = '',
  String title = '',
}) async {
  final subjectId = int.tryParse(bgmId);
  if (subjectId != null && subjectId > 0) return _subjectInfo(subjectId);

  final clean = title.replaceAll(_spaces, ' ').trim();
  if (clean.isEmpty) return null;

  // 标题变体彼此独立，并发发出后再统一打分，省掉串行往返。
  final batches = await Future.wait(
    BgmUtils.buildSearchTitles([clean]).map(_search),
  );

  final query = TitleFingerprint(clean);
  final querySeason = BgmUtils.extractSeason(clean);
  BgmSubjectInfo? best;
  BgmSubjectInfo? fallback;
  var bestScore = 0.0;

  for (final subjects in batches) {
    for (final subject in subjects) {
      fallback ??= subject;
      var score = 0.0;
      for (final candidate in subject.searchTitles) {
        final similarity = TitleFingerprint(candidate).similarityTo(query);
        if (similarity > score) score = similarity;
      }
      if (querySeason != null) {
        final season = BgmUtils.extractSeason(
          subject.nameCn ?? subject.name ?? '',
        );
        if (season != null && season != querySeason) continue;
        if (season == querySeason) score += 0.4;
      }
      if (score > bestScore) {
        bestScore = score;
        best = subject;
      }
    }
  }
  return best ?? fallback;
}

Future<BgmInfo> _fetchScore(String bgmId, String title) async {
  final cacheKey = _scoreCacheKey(bgmId, title);
  if (cacheKey == null) return const BgmInfo();

  final cached = _readCachedScore(cacheKey);
  if (cached != null) return cached;

  final subject = await resolveBgmSubject(bgmId: bgmId, title: title);
  if (subject == null) return const BgmInfo();

  final info = BgmInfo(
    score: subject.score,
    subjectId: subject.subjectId,
    imageUrl: subject.imageUrl,
  );
  await _scoreCache.write(cacheKey, {
    'score': info.score,
    'subjectId': info.subjectId,
    'imageUrl': info.imageUrl,
  });
  return info;
}

Future<List<BgmSubjectInfo>> _search(String keyword) async {
  final query = keyword.trim();
  if (query.isEmpty) return const [];
  try {
    return await _searchCache.get(query, () async {
      final response = await apiTransport.postMap(
        '$_bgmApiBase/v0/search/subjects?limit=10&offset=0',
        {
          'keyword': query,
          'sort': 'match',
          'filter': {
            'type': [2],
          },
        },
      );
      final items = response['data'] as List<dynamic>;
      return List<BgmSubjectInfo>.generate(
        items.length,
        (index) =>
            BgmSubjectInfo.fromJson(items[index] as Map<String, dynamic>),
        growable: false,
      );
    });
  } catch (error) {
    debugPrint('BGM search failed: $error');
    return const [];
  }
}

BgmInfo? _readCachedScore(String cacheKey) {
  final data = _scoreCache.read(cacheKey);
  if (data is! Map) return null;
  return BgmInfo(
    score: BgmUtils.toDouble(data['score']),
    subjectId: BgmUtils.toInt(data['subjectId']),
    imageUrl: data['imageUrl']?.toString(),
  );
}

String? _scoreCacheKey(String bgmId, String title) {
  final subjectId = int.tryParse(bgmId);
  if (subjectId != null && subjectId > 0) return 'bgm_score_$subjectId';

  final clean = title.replaceAll(_spaces, ' ').trim();
  final normalized = BgmUtils.normalizeTitle(clean);
  if (normalized.isEmpty) return null;
  final season = BgmUtils.extractSeason(clean);
  return season == null
      ? 'bgm_score_$normalized'
      : 'bgm_score_$normalized#season:$season';
}

List<Map<String, dynamic>> convertBgmSubjectsToAppFormat(
  List<Map<String, dynamic>> items, {
  bool trending = false,
}) {
  final result = <Map<String, dynamic>>[];
  for (final item in items) {
    final subject = trending ? item['subject'] as Map<String, dynamic> : item;

    final id = BgmUtils.toInt(subject['id']);
    if (id == null || id <= 0) continue;
    final nameCn = BgmUtils.trimmed(subject[trending ? 'nameCN' : 'name_cn']);
    final name = BgmUtils.trimmed(subject['name']);
    final title = nameCn ?? name;
    if (title == null) continue;

    final imageUrl = BgmUtils.pickImageUrl(subject['images']) ?? '';
    final rating = subject['rating'];
    final converted = <String, dynamic>{
      'id': id,
      'title': title,
      'subtitle': nameCn != null && name != null && name != nameCn ? name : '',
      'content': imageUrl,
      'bgmImageUrl': imageUrl,
      'tag': '动画',
      'sort': trending ? '推荐' : '',
      'status': 'public',
      'time': BgmUtils.trimmed(subject['date']) ?? '',
      'bgmId': id,
      'score': BgmUtils.extractScore(rating) ?? 0.0,
      'rank': BgmUtils.toInt(rating is Map ? rating['rank'] : null) ?? 0,
      'summary': BgmUtils.trimmed(subject['summary']) ?? '',
      'eps': subject['eps'] ?? subject['total_episodes'] ?? 0,
      'source': 'bgm',
    };
    if (trending) {
      converted['info'] = BgmUtils.trimmed(subject['info']) ?? '';
      converted['videos'] = '';
    }
    result.add(converted);
  }
  return result;
}
