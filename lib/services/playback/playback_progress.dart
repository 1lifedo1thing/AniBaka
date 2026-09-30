import 'package:baka/models/playback_request.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/history_repository.dart';

/// Belongs to the opened media, independently of a pending episode selection.
class PlaybackProgress {
  PlaybackProgress({
    required this.history,
    required PlaybackRequest request,
    required this.videoKey,
    required Duration start,
    this.bgmId,
    this.cover,
  }) : request = request.copyWith(),
       _pendingStart = start;

  final HistoryRepository history;
  final PlaybackRequest request;
  final String videoKey;
  final int? bgmId;
  final String? cover;
  Duration _pendingStart;

  Future<void> save(
    PlaybackTimelineState timeline, {
    required bool rememberPosition,
    bool seeked = false,
  }) async {
    if (timeline.duration <= Duration.zero || timeline.seeking) return;
    final position = timeline.position;
    if (seeked) _pendingStart = Duration.zero;
    // Opening with a start offset may emit zero before the native seek settles.
    if (_pendingStart > Duration.zero) {
      if (position + const Duration(seconds: 1) < _pendingStart) return;
      _pendingStart = Duration.zero;
    }
    if (position < Duration.zero || (!seeked && position == Duration.zero)) {
      return;
    }
    await Future.wait([
      if (rememberPosition && videoKey.isNotEmpty)
        history.saveProgress(videoKey, position, duration: timeline.duration),
      if (request.source != '_local')
        history.saveHistory(
          request: request,
          episodeIndex: request.episodeIndex ?? 0,
          urlIndex: request.lineIndex ?? 1,
          positionMs: position.inMilliseconds,
          durationMs: timeline.duration.inMilliseconds,
          bgmId: bgmId,
          cover: cover,
        ),
    ]);
  }
}
