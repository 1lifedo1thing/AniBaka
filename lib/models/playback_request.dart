import 'package:baka/models/playback_episode.dart';

/// Shared handoff between matching, navigation and a playback session.
/// Legacy metadata is retained by reference; episode catalogs are decoded once.
class PlaybackRequest {
  PlaybackRequest.fromMap(Map data)
    : metadata = data.cast<String, dynamic>(),
      episodes = PlaybackEpisodeCatalog.episodesOf(
        data,
        mergeDuplicateTitles: true,
      ),
      episodeIndex = int.tryParse('${data['currPlayIndex']}') ?? 0,
      lineIndex = int.tryParse('${data['currUrl']}') ?? 1,
      sourceNames = (data['sourceNames'] as List?)?.cast<String>(),
      prefetched = data['_prefetchedPlayback'] as PrefetchedMedia?;

  final Map<String, dynamic> metadata;
  final List<PlaybackEpisode> episodes;
  final List<String>? sourceNames;
  final int episodeIndex;
  final int lineIndex;
  PrefetchedMedia? prefetched;
  String get source => metadata['source'] as String? ?? '';
  Object? get contentId => metadata['seriesId'] ?? metadata['id'];
  Map<String, String>? get httpHeaders =>
      (metadata['httpHeaders'] as Map?)?.cast<String, String>();
}

class PrefetchedMedia {
  const PrefetchedMedia({
    required this.source,
    required this.episodeIndex,
    required this.lineIndex,
    required this.episodeId,
    required this.url,
    required this.httpHeaders,
    required this.resolvedAt,
  });
  final String source, episodeId, url;
  final int episodeIndex, lineIndex, resolvedAt;
  final Map<String, String> httpHeaders;

  bool matches(String sourceKey, int episode, int line, String id, int now) =>
      source == sourceKey &&
      episodeIndex == episode &&
      lineIndex == line &&
      episodeId == id &&
      url.isNotEmpty &&
      now >= resolvedAt &&
      now - resolvedAt <= const Duration(minutes: 10).inMilliseconds;
}
