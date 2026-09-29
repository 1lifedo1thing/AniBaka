import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:baka/services/torrent/torrent_engine.dart';
import 'package:baka/services/torrent/torrent_model.dart';

/// Owns the single active BT session and exposes one shared UI snapshot.
class TorrentService {
  TorrentService();
  static const Duration defaultBufferTimeout = Duration(seconds: 30);
  static const Duration _statsPublishInterval = Duration(milliseconds: 500);

  TorrentEngine? _engine;
  Timer? _statsTimer;
  DateTime? _lastStatsPublishedAt;
  Completer<void> _nextUpdate = Completer<void>();
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _disposing;
  Future<void>? _stopping;

  final ValueNotifier<TorrentStats?> statsNotifier = ValueNotifier(null);

  static bool isBtLink(String value) => isTorrentLink(value);

  Future<({String? url, TorrentEngine engine})?> _startStream(
    String url,
    int generation,
  ) async {
    if (_disposed) throw StateError('TorrentService is disposed');
    await _stopEngine();
    if (_disposed || generation != _generation) return null;
    final target = url.trim();
    if (!isTorrentLink(target)) return null;

    final engine = TorrentEngine();
    _engine = engine;
    engine.onChanged = () {
      if (!identical(_engine, engine)) return;
      _signalUpdate();
      _scheduleStatsPublish(engine);
    };
    _publishStats(engine);

    final streamUrl = target.toLowerCase().startsWith('magnet:')
        ? await engine.startFromMagnet(target)
        : await engine.startFromTorrentUrl(target);
    if (!identical(_engine, engine)) {
      unawaited(engine.dispose());
      return null;
    }
    return (url: streamUrl, engine: engine);
  }

  Future<String> resolvePlaybackUrl(
    String url, {
    Duration bufferTimeout = defaultBufferTimeout,
  }) async {
    final target = url.trim();
    if (!isTorrentLink(target)) return target;
    if (_disposed) throw StateError('TorrentService is disposed');
    final generation = ++_generation;
    final clock = Stopwatch()..start();
    final deadline = Timer(bufferTimeout, () {
      if (generation == _generation) unawaited(stopStream());
    });
    try {
      final stream = await _startStream(target, generation);
      if (stream == null || stream.url == null) {
        throw TorrentPlaybackException(
          stream?.engine.errorMessage ?? 'BT stream was stopped or timed out',
        );
      }
      await _waitUntilBuffered(stream.engine, bufferTimeout - clock.elapsed);
      return stream.url!;
    } catch (_) {
      if (generation == _generation) await stopStream();
      rethrow;
    } finally {
      deadline.cancel();
    }
  }

  Future<void> stopStream() async {
    _generation++;
    await _stopEngine();
  }

  Future<void> _stopEngine() async {
    final engine = _engine;
    _engine = null;
    if (engine != null) engine.onChanged = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastStatsPublishedAt = null;
    if (!_disposed) statsNotifier.value = null;
    _signalUpdate();
    if (engine != null) _stopping = engine.dispose();
    // A second stop/dispose must also wait for an already detached engine.
    await _stopping;
  }

  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    try {
      await stopStream();
    } finally {
      statsNotifier.dispose();
    }
  }

  Future<void> _waitUntilBuffered(
    TorrentEngine engine,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (!identical(_engine, engine)) {
        throw const TorrentPlaybackException('BT stream was stopped');
      }
      if (engine.state == TorrentState.error) {
        throw TorrentPlaybackException(
          engine.errorMessage ?? 'BT stream entered an error state',
        );
      }
      if (engine.isReadyToPlay) return;

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TorrentPlaybackException(
          'BT buffer timed out after ${timeout.inSeconds}s',
        );
      }
      try {
        await _nextUpdate.future.timeout(remaining);
      } on TimeoutException {
        throw TorrentPlaybackException(
          'BT buffer timed out after ${timeout.inSeconds}s',
        );
      }
    }
  }

  void _signalUpdate() {
    final update = _nextUpdate;
    if (!_disposed) _nextUpdate = Completer<void>();
    if (!update.isCompleted) update.complete();
  }

  void _scheduleStatsPublish(TorrentEngine engine) {
    if (_statsTimer != null) return;
    final now = DateTime.now();
    final elapsed = _lastStatsPublishedAt == null
        ? _statsPublishInterval
        : now.difference(_lastStatsPublishedAt!);
    if (elapsed >= _statsPublishInterval) {
      _publishStats(engine);
      return;
    }
    _statsTimer = Timer(_statsPublishInterval - elapsed, () {
      _statsTimer = null;
      _publishStats(engine);
    });
  }

  void _publishStats(TorrentEngine engine) {
    if (!identical(_engine, engine)) return;
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastStatsPublishedAt = DateTime.now();
    statsNotifier.value = engine.getStats();
  }
}

class TorrentPlaybackException implements Exception {
  const TorrentPlaybackException(this.message);

  final String message;

  @override
  String toString() => 'TorrentPlaybackException: $message';
}
