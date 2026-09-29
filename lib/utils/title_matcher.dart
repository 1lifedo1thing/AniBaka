import 'package:baka/utils/reg_utils.dart';

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

  /// 小写并去掉常见噪音字符与修饰短语。字符集与 [buildSearchTitles] 共用，
  /// 但保留季号——季度冲突由 SourceMatchEngine 单独判定。
  static String normalize(String title) {
    final cleaned = title.replaceAll(_noiseRe, ' ');
    return keepTitleUnits(cleaned);
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

final _spaceRe = RegExp(r'\s+');
final _trailingBracketRe = RegExp(r'\s*[\(\[（【][^\)\]）】]+[\)\]）】]\s*$');

final _seasonNumRe = RegExp(
  r'第\s*([一二三四五六七八九十]+|\d+)\s*[季期]|season\s*(\d+)|\bs(\d+)\b|part\s*(\d+)',
  caseSensitive: false,
);

int? extractSeason(String text) {
  final m = _seasonNumRe.firstMatch(text);
  if (m == null) return null;
  final cn = m.group(1);
  if (cn != null) {
    return int.tryParse(cn) ?? _parseChineseNumber(cn);
  }
  return int.tryParse(m.group(2) ?? m.group(3) ?? m.group(4) ?? '');
}

/// 解析 1-99 范围内的中文数字（一、十二、二十三……）。
int? _parseChineseNumber(String raw) {
  const digits = <String, int>{
    '零': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  final tenIndex = raw.indexOf('十');
  if (tenIndex == -1) return digits[raw];

  final tens = tenIndex == 0 ? 1 : digits[raw.substring(0, tenIndex)];
  final onesPart = raw.substring(tenIndex + 1);
  final ones = onesPart.isEmpty ? 0 : digits[onesPart];
  if (tens == null || ones == null) return null;
  return tens * 10 + ones;
}

bool _isTitleUnit(int unit) =>
    (unit >= 0x61 && unit <= 0x7A) || // a-z
    (unit >= 0x30 && unit <= 0x39) || // 0-9
    (unit >= 0x4E00 && unit <= 0x9FA5); // CJK

/// 单趟扫描完成「小写 + 过滤」，取代 `toLowerCase()` 与正则 `replaceAll`
/// 各分配一次全串的写法；输入已是规范形式时原样返回，零分配。
String keepTitleUnits(String text) {
  var i = 0;
  while (i < text.length && _isTitleUnit(text.codeUnitAt(i))) {
    i++;
  }
  if (i == text.length) return text;

  final buffer = StringBuffer(text.substring(0, i));
  for (; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0x41 && unit <= 0x5A) {
      buffer.writeCharCode(unit + 0x20); // A-Z -> a-z
    } else if (unit == 0x130) {
      buffer.writeCharCode(0x69); // İ 小写为 i + 组合点，组合点本就会被过滤
    } else if (unit == 0x212A) {
      buffer.writeCharCode(0x6B); // 开尔文符号 K 小写为 k
    } else if (_isTitleUnit(unit)) {
      buffer.writeCharCode(unit);
    }
  }
  return buffer.toString();
}

/// 仅保留汉字，用于派生「纯中文」搜索变体。
String _chineseOnly(String text) {
  var i = 0;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x4E00 || unit > 0x9FA5) break;
    i++;
  }
  if (i == text.length) return text;
  final buffer = StringBuffer(text.substring(0, i));
  for (; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0x4E00 && unit <= 0x9FA5) buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

/// 为每个标题派生搜索变体（原文 / 去季号 / 去尾括号 / 纯中文），按归一化去重。
List<String> buildSearchTitles(Iterable<String?> titles) {
  final values = <String>[];
  final seen = <String>{};

  void add(String value, String key) {
    if (key.isNotEmpty && seen.add(key)) values.add(value);
  }

  for (final raw in titles) {
    final title = raw?.trim().replaceAll(_spaceRe, ' ');
    if (title == null || title.isEmpty) continue;

    final base = RegUtils.extractBaseTitle(title);
    add(title, keepTitleUnits(base));

    final base2 = RegUtils.extractBaseTitle(base);
    if (base2 != base) add(base, keepTitleUnits(base2));

    if (_endsWithBracket(title)) {
      final stripped = title.replaceFirst(_trailingBracketRe, '');
      if (stripped.isNotEmpty) {
        add(stripped, keepTitleUnits(RegUtils.extractBaseTitle(stripped)));
      }
    }

    final zh = _chineseOnly(title);
    if (zh.isNotEmpty && zh != title) {
      add(zh, keepTitleUnits(RegUtils.extractBaseTitle(zh)));
    }
  }
  return values;
}

bool _endsWithBracket(String title) {
  final tail = title.trimRight();
  if (tail.isEmpty) return false;
  return switch (tail.codeUnitAt(tail.length - 1)) {
    0x29 || 0x5D || 0xFF09 || 0x3011 => true,
    _ => false,
  };
}
