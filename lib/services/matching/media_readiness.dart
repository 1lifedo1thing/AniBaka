import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/services/torrent/torrent_model.dart';

/// 线路 token / 媒体 URL 的就绪分类。
enum MediaTokenKind {
  /// m3u8 / mp4 / 签名 CDN / 对象存储等，可直接交给播放器。
  directMedia,

  /// magnet / torrent。
  torrent,

  /// 需要走源适配器 `resolvePlaybackMedia` 再取真实地址。
  needsResolve,

  empty,
}

class MediaReadiness {
  MediaReadiness._();

  /// 分类单条线路 token。
  static MediaTokenKind classify(String? token) {
    final value = token?.trim() ?? '';
    if (value.isEmpty) return MediaTokenKind.empty;
    if (isTorrentLink(value)) return MediaTokenKind.torrent;
    if (_looksLikeDirectMedia(value)) return MediaTokenKind.directMedia;
    return MediaTokenKind.needsResolve;
  }

  /// 已解析出的播放地址是否可接受为“可播”。
  static bool isAcceptablePlaybackUrl(String? url) {
    final value = url?.trim() ?? '';
    if (value.isEmpty) return false;
    if (isTorrentLink(value)) return true;
    if (VideoUrlExtractor.isPlayable(value) || VideoUrlExtractor.isVideoUrl(value)) {
      return true;
    }
    return _looksLikeBareStream(value);
  }

  static bool isDirectMedia(String? token) =>
      classify(token) == MediaTokenKind.directMedia;

  static bool needsResolve(String? token) =>
      classify(token) == MediaTokenKind.needsResolve;

  static bool _looksLikeDirectMedia(String value) =>
      VideoUrlExtractor.isPlayable(value) ||
      VideoUrlExtractor.isVideoUrl(value);

  /// 形态不定但确实是取流地址（网盘直链、`/api/media?id=` 等）。
  static bool _looksLikeBareStream(String value) =>
      VideoUrlExtractor.looksLikeBareStream(value);
}
