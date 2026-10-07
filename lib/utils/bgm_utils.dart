class BgmUtils {
  static final _bbQuoteRe = RegExp(r'\[quote\].*?\[/quote\]', dotAll: true);
  static final _bbTagRe = RegExp(r'\[/?[a-zA-Z]+(?:=[^\]]+)?\]');
  static final _bgmEmojiRe = RegExp(r'\(bgm\d+\)');

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

  static double? extractScore(Map? rating) {
    final score = rating?['score'] as num?;
    return (score != null && score > 0) ? score.toDouble() : null;
  }

  static String cleanBbCode(String text) => text
      .replaceAll(_bbQuoteRe, '')
      .replaceAll(_bbTagRe, '')
      .replaceAll(_bgmEmojiRe, '')
      .trim();
}
