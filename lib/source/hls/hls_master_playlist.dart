/// 主清单（master playlist）里的一个码率变体。
class HlsVariantPlaylist {
  const HlsVariantPlaylist({
    required this.uri,
    required this.bandwidth,
    this.resolution,
  });

  /// 变体媒体清单地址（已按主清单地址解析成绝对地址）。
  final Uri uri;

  /// `BANDWIDTH`，缺省或非法时按 0 处理。
  final int bandwidth;

  /// `RESOLUTION` 原文，仅用于日志。
  final String? resolution;

  /// 一行说明，用于日志。
  String get label => '${resolution ?? '?'}@${bandwidth ~/ 1000}kbps';
}

/// 主清单解析：只在开启去广告时用来补「主清单 → 单个变体媒体清单」这一跳。
///
/// 分片广告只存在于媒体清单里，主清单本身没有分片，因此去广告必须落到某一个
/// 具体变体上。选定变体后整条链路固定在该变体，自适应码率不再生效——这是本
/// 模块只在规则显式开启 `filterHlsAds` 时才被使用的原因。
abstract final class HlsMasterPlaylist {
  static final RegExp _streamInf = RegExp(
    r'^#EXT-X-STREAM-INF:(.*)$',
    multiLine: true,
  );
  static final RegExp _bandwidth = RegExp(r'BANDWIDTH=(\d+)');
  static final RegExp _resolution = RegExp(r'RESOLUTION=([0-9]+x[0-9]+)');
  static final RegExp _alternativeRendition = RegExp(
    r'^#EXT-X-MEDIA:',
    multiLine: true,
  );

  /// 含 `#EXT-X-STREAM-INF` 的是主清单；媒体清单不会出现该标签
  /// （`#EXT-X-I-FRAME-STREAM-INF` 不匹配）。
  static bool isMaster(String body) => _streamInf.hasMatch(body);

  /// 主清单是否带独立音轨 / 字幕等替代 rendition。
  ///
  /// 带的话不接管：只把某个视频变体交给播放器会丢掉这些轨。
  static bool hasAlternativeRenditions(String body) =>
      _alternativeRendition.hasMatch(body);

  /// 所有码率变体，按出现顺序。
  static List<HlsVariantPlaylist> variants(String body, Uri baseUri) {
    final lines = body.replaceAll('\r\n', '\n').split('\n');
    final variants = <HlsVariantPlaylist>[];
    for (var i = 0; i < lines.length; i++) {
      final match = _streamInf.firstMatch(lines[i].trim());
      if (match == null) continue;
      final attributes = match.group(1)!;
      final uri = _followingUri(lines, i + 1, baseUri);
      if (uri == null) continue;
      variants.add(
        HlsVariantPlaylist(
          uri: uri,
          bandwidth:
              int.tryParse(_bandwidth.firstMatch(attributes)?.group(1) ?? '') ??
              0,
          resolution: _resolution.firstMatch(attributes)?.group(1),
        ),
      );
    }
    return variants;
  }

  /// 选定一个变体：取 `BANDWIDTH` 最大的那个。
  ///
  /// 带替代 rendition、没有变体、或变体地址都不可解析时返回 null，调用方应放弃
  /// 去广告并回落到原始地址。
  static HlsVariantPlaylist? selectVariant(String body, Uri baseUri) {
    if (hasAlternativeRenditions(body)) return null;
    final all = variants(body, baseUri);
    if (all.isEmpty) return null;
    return all.reduce((a, b) => b.bandwidth > a.bandwidth ? b : a);
  }

  /// `#EXT-X-STREAM-INF` 之后第一个非空、非标签行就是变体地址。
  static Uri? _followingUri(List<String> lines, int from, Uri baseUri) {
    for (var i = from; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      try {
        return baseUri.resolve(line);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
