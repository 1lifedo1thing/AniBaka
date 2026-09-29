import 'package:baka/utils/json_values.dart';

class BgmUtils {
  static final _bbQuoteRe = RegExp(r'\[quote\].*?\[/quote\]', dotAll: true);
  static final _bbTagRe = RegExp(r'\[/?[a-zA-Z]+(?:=[^\]]+)?\]');
  static final _bgmEmojiRe = RegExp(r'\(bgm\d+\)');

  static final _yyyymmddRe = RegExp(r'^\d{8}');
  static final _plainDateRe = RegExp(
    r'^(\d{4})[-/.年]?(\d{1,2})(?:[-/.月]?(\d{1,2}))?',
  );
  static final _airDateKeyRe = RegExp(r'放送|上映|发售|首播');

  static String? pickImageUrl(dynamic rawImages) {
    if (rawImages is! Map) return null;
    return trimmed(
      rawImages['large'] ??
          rawImages['common'] ??
          rawImages['medium'] ??
          rawImages['small'],
    );
  }

  /// Returns a cached cover URL that does not redirect the client to
  /// Bangumi's blocked image host.
  static String bgmCoverProxyUrl(int subjectId) {
    final source = Uri.https(
      'api.bgm.tv',
      '/v0/subjects/$subjectId/image',
      const {'type': 'large'},
    );
    return bgmImageProxyUrl(source.toString());
  }

  /// WordPress Photon 等 CDN：`https://i1.wp.com/lain.bgm.tv/...`。
  /// p1.anibaka.com 返回的头像常已包过一层；再套 wsrv.nl 会 400。
  static final _wpPhotonHostRe = RegExp(
    r'^i\d+\.wp\.com$',
    caseSensitive: false,
  );

  /// 从 avatar map / 字符串中取可用头像 URL（优先 medium）。
  static String pickAvatarUrl(dynamic avatar) {
    if (avatar is String) return trimmed(avatar) ?? '';
    if (avatar is! Map) return '';
    return trimmed(
          avatar['medium'] ??
              avatar['large'] ??
              avatar['small'] ??
              avatar['common'],
        ) ??
        '';
  }

  /// Wraps any Bangumi image URL (lain.bgm.tv is blocked for many users)
  /// with the same wsrv.nl cache used by search covers.
  static String bgmImageProxyUrl(String url, {int width = 360}) {
    if (url.isEmpty) return url;
    if (url.contains('wsrv.nl')) return url;
    final formatted = _normalizeBgmImageSource(url);
    if (formatted.isEmpty) return '';
    return Uri.https('wsrv.nl', '/', {
      'url': formatted,
      'w': '$width',
      'output': 'webp',
      'q': '85',
    }).toString();
  }

  /// 规范化图片源地址：补全协议、拆掉已存在的 Photon 嵌套代理。
  static String _normalizeBgmImageSource(String url) {
    var formatted = url.trim();
    if (formatted.isEmpty) return '';
    if (formatted.startsWith('//')) {
      formatted = 'https:$formatted';
    }

    final uri = Uri.tryParse(formatted);
    if (uri == null || !uri.hasScheme) return formatted;

    // https://i1.wp.com/lain.bgm.tv/r/100/pic/user/...jpg?r=1
    // → https://lain.bgm.tv/r/100/pic/user/...jpg?r=1
    if (_wpPhotonHostRe.hasMatch(uri.host) && uri.pathSegments.isNotEmpty) {
      final originHost = uri.pathSegments.first;
      return Uri(
        scheme: 'https',
        host: originHost,
        path: '/${uri.pathSegments.skip(1).join('/')}',
        query: uri.hasQuery ? uri.query : null,
      ).toString();
    }

    return formatted;
  }

  static double? extractScore(dynamic rating) {
    final score = (rating is Map) ? rating['score'] : null;
    return (score is num && score > 0) ? score.toDouble() : null;
  }

  static String formatTimeString(String raw, String prefix) {
    if (raw.length >= 8 && _yyyymmddRe.hasMatch(raw)) {
      return '$prefix ${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6, 8)}';
    }
    return '$prefix ${raw.length >= 10 ? raw.substring(0, 10) : raw}';
  }

  static String? formatPlainDate(dynamic raw) {
    final text = trimmed(raw);
    if (text == null) return null;

    final match = _plainDateRe.firstMatch(text);
    if (match != null) {
      final y = int.tryParse(match.group(1) ?? '');
      final m = int.tryParse(match.group(2) ?? '');
      final d = int.tryParse(match.group(3) ?? '');
      if (y != null && y > 0 && m != null && m > 0) {
        return (d == null || d <= 0) ? '$y.$m' : '$y.$m.$d';
      }
    }

    final parsed = DateTime.tryParse(text);
    if (parsed != null) return '${parsed.year}.${parsed.month}.${parsed.day}';
    return null;
  }

  static String? formatAirDate(Map data) {
    final detail = asMap(data['bgmDetailData']);
    return formatPlainDate(data['airDate']) ??
        formatPlainDate(detail?['date']) ??
        formatPlainDate(detail?['air_date']) ??
        formatPlainDate(detail?['airDate']) ??
        _extractInfoboxAirDate(detail?['infobox']) ??
        formatPlainDate(data['time']);
  }

  static String? _extractInfoboxAirDate(dynamic rawInfobox) {
    for (final item in asMapList(rawInfobox)) {
      final key = item['key']?.toString() ?? '';
      if (_airDateKeyRe.hasMatch(key)) {
        final formatted = _formatInfoboxDateValue(item['value']);
        if (formatted != null) return formatted;
      }
    }
    return null;
  }

  static String? _formatInfoboxDateValue(dynamic value) {
    if (value is List) {
      for (final item in value) {
        final nested = _formatInfoboxDateValue(item);
        if (nested != null) return nested;
      }
    } else if (value is Map) {
      for (final item in value.values) {
        final nested = _formatInfoboxDateValue(item);
        if (nested != null) return nested;
      }
    } else {
      return formatPlainDate(value);
    }
    return null;
  }

  static String cleanBbCode(String text) => text
      .replaceAll(_bbQuoteRe, '')
      .replaceAll(_bbTagRe, '')
      .replaceAll(_bgmEmojiRe, '')
      .trim();
}
