import 'package:baka/utils/json_values.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';
import 'package:baka/utils/title_matcher.dart';

class BgmInfo {
  final double? score;
  final int? subjectId;
  final String? imageUrl;

  const BgmInfo({this.score, this.subjectId, this.imageUrl});
  factory BgmInfo.fromData(Map data) {
    final detail = data['bgmDetailData'] as Map?;
    return BgmInfo(
      subjectId: toInt(data['bgmId'] ?? detail?['id']),
      score: toDouble(
        data['score'] ?? BgmUtils.extractScore(detail?['rating']),
      ),
      imageUrl: _readBgmImageUrl(data),
    );
  }
}

class BgmSubjectInfo {
  final int subjectId;
  final String? name;
  final String? nameCn;
  final String? summary;
  final String? imageUrl;
  final double? score;

  late final List<String> searchTitles = buildSearchTitles([nameCn, name]);

  BgmSubjectInfo({
    required this.subjectId,
    this.name,
    this.nameCn,
    this.summary,
    this.imageUrl,
    this.score,
  });

  factory BgmSubjectInfo.fromJson(Map<String, dynamic> data) => BgmSubjectInfo(
    subjectId: data['id'] as int,
    name: trimmed(data['name']),
    nameCn: trimmed(data['name_cn']),
    summary: trimmed(data['summary']),
    imageUrl: trimmed((data['images'] as Map<String, dynamic>)['large']),
    score: ((data['rating'] as Map<String, dynamic>)['score'] as num)
        .toDouble(),
  );
}

String? _readBgmImageUrl(Map data) {
  final detail = data['bgmDetailData'] as Map?;
  return trimmed(data['bgmImageUrl']) ??
      BgmUtils.pickImageUrl(detail?['images']);
}

String? _readContentImage(dynamic content) {
  final suo = trimmed(getSuo(content?.toString()));
  return (suo == kDefaultImage) ? null : suo;
}

String? resolveCoverImage(Map data, {BgmInfo? bgmInfo}) {
  return trimmed(bgmInfo?.imageUrl) ??
      _readBgmImageUrl(data) ??
      trimmed(data['image']) ??
      _readContentImage(data['content']);
}

/// Convert once at the legacy card/page boundary; API caches keep upstream data.
List<Map<String, dynamic>> convertBgmSubjectsToAppFormat(
  List<Map<String, dynamic>> items, {
  bool trending = false,
  // Card lists that open by bgmId do not need to retain full subject metadata.
  bool compact = false,
}) {
  final result = <Map<String, dynamic>>[];
  for (final item in items) {
    final subject = trending ? item['subject'] as Map<String, dynamic> : item;

    final id = toInt(subject['id']);
    if (id == null || id <= 0) continue;
    final nameCn = trimmed(subject[trending ? 'nameCN' : 'name_cn']);
    final name = trimmed(subject['name']);
    final title = nameCn ?? name;
    if (title == null) continue;

    final imageUrl = BgmUtils.pickImageUrl(subject['images']) ?? '';
    final rating = subject['rating'];
    final converted = <String, dynamic>{
      if (!compact) 'id': id,
      'title': title,
      'subtitle': nameCn != null && name != null && name != nameCn ? name : '',
      'content': imageUrl,
      'bgmImageUrl': imageUrl,
      if (!compact) 'tag': '动画',
      if (!compact) 'sort': trending ? '推荐' : '',
      if (!compact) 'status': 'public',
      if (!compact) 'time': trimmed(subject['date']) ?? '',
      'bgmId': id,
      'score': BgmUtils.extractScore(rating) ?? 0.0,
      if (!compact) 'rank': toInt(rating is Map ? rating['rank'] : null) ?? 0,
      if (!compact) 'summary': trimmed(subject['summary']) ?? '',
      if (!compact) 'eps': subject['eps'] ?? subject['total_episodes'] ?? 0,
      'source': 'bgm',
    };
    if (trending) {
      converted['info'] = trimmed(subject['info']) ?? '';
      converted['videos'] = '';
    }
    result.add(converted);
  }
  return result;
}
