import 'package:baka/utils/bgm_utils.dart';

/// 标题模糊匹配：归一化 + 子串包含判定。
///
/// 只保留最快的判定：归一化后一方包含另一方即按长度比例给分。
/// 不再为每个候选构建 bigram 集合做 Dice 相似度——那需要 O(n) 的
/// 分配与集合运算，而候选数远多于实际命中数。
class TitleFingerprint {
  TitleFingerprint(String raw) : normalized = normalize(raw);

  final String normalized;
  late final bool _hasModifier = _modifierRe.hasMatch(normalized);

  bool get isEmpty => normalized.isEmpty;

  static final RegExp _noiseRe = RegExp(
    r'\[.*?\]|【.*?】|\(.*?\)|\（.*?\）|1080p?|720p?|4k|bdrip|webrip|无修|招募|字幕组|简日|繁日|国语|双语|全\d+集',
    caseSensitive: false,
  );

  static final RegExp _modifierRe = RegExp(
    r'剧场版|劇場版|映画|movie|ova|oad|special|特别篇|特別編|第二季|第三季|第四季|第[一二三四五六七八九十\d]+季|2nd|3rd|4th|season\s*\d+',
    caseSensitive: false,
  );

  /// 小写并去掉常见噪音字符与修饰短语。字符集与 [BgmUtils.normalizeTitle] 共用，
  /// 但保留季号——季度冲突由 SourceMatchEngine 单独判定。
  static String normalize(String title) {
    final cleaned = title.replaceAll(_noiseRe, ' ');
    return BgmUtils.keepTitleUnits(cleaned);
  }

  /// 相似度 ∈ [0,1]；不构成子串关系的标题直接判 0。
  double similarityTo(TitleFingerprint other) {
    if (isEmpty || other.isEmpty) return 0;
    if (normalized == other.normalized) return 1;

    final a = normalized;
    final b = other.normalized;
    final shorter = a.length <= b.length ? a : b;
    final longer = a.length > b.length ? a : b;
    if (!longer.contains(shorter)) return 0;

    // 一方含剧场版/季号而另一方不含时，子串关系不足以说明是同一部。
    final modMismatch = _hasModifier != other._hasModifier;
    final base = 0.65 + (shorter.length / longer.length) * 0.25;
    return (modMismatch ? base * 0.6 : base).clamp(0.0, 0.95);
  }
}
