import 'dart:async';
import 'dart:io';
import 'dart:math' show min;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:baka/services/torrent/torrent_model.dart';
import 'package:baka/services/torrent/tracker_client.dart';
import 'package:baka/services/torrent/peer_protocol.dart';
import 'package:baka/services/torrent/piece_manager.dart';
import 'package:baka/services/torrent/stream_server.dart';

/// Torrent 下载状态
enum TorrentState { idle, resolving, connecting, downloading, seeding, error }

/// 强类型下载统计
class TorrentStats {
  final TorrentState state;
  final int peers;
  final double progress;
  final int downloadedBytes;
  final int uploadedBytes;
  final int totalBytes;
  final int contiguousBytes;
  final int bufferRequiredBytes;
  final bool readyToPlay;
  final double downloadSpeed;
  final double uploadSpeed;
  final String? errorMessage;
  final int firstPiece;
  final int lastPiece;
  final List<PieceState> pieceStates;

  const TorrentStats({
    this.state = TorrentState.idle,
    this.peers = 0,
    this.progress = 0.0,
    this.downloadedBytes = 0,
    this.uploadedBytes = 0,
    this.totalBytes = 0,
    this.contiguousBytes = 0,
    this.bufferRequiredBytes = 0,
    this.readyToPlay = false,
    this.downloadSpeed = 0.0,
    this.uploadSpeed = 0.0,
    this.errorMessage,
    this.firstPiece = 0,
    this.lastPiece = -1,
    this.pieceStates = const <PieceState>[],
  });
}

/// Torrent 引擎 — 编排 tracker、peer、piece 管理和流媒体服务器
class TorrentEngine {
  bool _disposed = false;
  Future<void>? _disposing;
  final _stopped = Completer<void>();
  final _cancelToken = CancelToken();
  final _tracker = TrackerClient();
  final Set<PeerConnection> _connectingPeers = {};
  final Set<MetadataPeerConnection> _metadataPeers = {};
  TorrentMetadata? _metadata;
  PieceManager? _pieceManager;
  final TorrentStreamServer _streamServer = TorrentStreamServer();
  final List<PeerConnection> _peers = [];
  final Dio _dio = Dio(
    BaseOptions(
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/122.0 Safari/537.36',
        'Accept': 'application/x-bittorrent,*/*',
      },
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.bytes,
    ),
  );

  Timer? _announceTimer;
  Timer? _peerCheckTimer;
  ServerSocket? _peerServer;
  bool _isConnectingPeers = false;
  int _listenPort = TrackerClient.defaultListenPort;

  TorrentState _state = TorrentState.idle;
  TorrentState get state => _state;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool get isReadyToPlay => _pieceManager?.isReadyToPlay == true;

  void Function()? onChanged;

  bool _readyNotified = false;
  static const int _minBufferBytes = 2 * 1024 * 1024; // 2MB 最小缓冲
  static const int _maxPeers = 30;

  int _lastSpeedBytes = 0;
  int _lastUploadBytes = 0;
  int _uploadedBytes = 0;
  final Stopwatch _speedClock = Stopwatch()..start();
  int _lastSpeedAtMs = 0;
  double _downloadSpeed = 0;
  double _uploadSpeed = 0;

  /// 从 .torrent 文件 URL 开始下载
  Future<String?> startFromTorrentUrl(String torrentUrl) async {
    _setState(TorrentState.resolving);
    try {
      final response = await _dio.get<List<int>>(
        torrentUrl,
        cancelToken: _cancelToken,
      );
      if (_disposed) return null;
      if (response.data == null) {
        _setError('下载 .torrent 文件失败');
        return null;
      }
      final bytes = _responseBytes(response.data!);
      _metadata = TorrentMetadata.fromBytes(bytes);
      return await _startDownload();
    } catch (e) {
      _setError('解析 torrent 失败: $e');
      return null;
    }
  }

  /// 从 magnet 链接开始下载
  Future<String?> startFromMagnet(String magnetUri) async {
    _setState(TorrentState.resolving);
    try {
      final magnet = MagnetLink.parse(magnetUri);

      final metadata = await _resolveMagnetMetadata(magnet);
      if (_disposed) return null;
      _metadata = metadata;
      if (_metadata == null) {
        _setError('无法通过 BEP 9 或 magnet 精确来源获取种子元数据');
        return null;
      }

      return await _startDownload();
    } catch (e) {
      _setError('Magnet 解析失败: $e');
      return null;
    }
  }

  Future<TorrentMetadata?> _resolveMagnetMetadata(MagnetLink magnet) async {
    final completer = Completer<TorrentMetadata?>();
    final tasks = <Future<TorrentMetadata?>>[
      _fetchMetadataViaPeers(magnet),
      if (magnet.exactSources.isNotEmpty)
        _fetchMetadataFromExactSources(magnet),
    ];
    var remaining = tasks.length;

    void complete(TorrentMetadata? metadata) {
      if (metadata != null && !completer.isCompleted) {
        completer.complete(metadata);
        return;
      }
      remaining--;
      if (remaining == 0 && !completer.isCompleted) {
        completer.complete(null);
      }
    }

    for (final task in tasks) {
      unawaited(
        task.then(complete).catchError((_) {
          complete(null);
        }),
      );
    }

    try {
      return await Future.any([
        completer.future,
        _stopped.future.then((_) => null),
      ]);
    } finally {
      _cancelToken.cancel();
      for (final peer in _metadataPeers.toList()) {
        peer.disconnect();
      }
    }
  }

  Future<String?> _startDownload() async {
    if (_disposed) return null;
    final meta = _metadata!;
    debugPrint('[TorrentEngine] 开始下载: ${meta.name}');
    debugPrint(
      '[TorrentEngine] 文件数: ${meta.files.length}, '
      '总大小: ${(meta.totalSize / 1024 / 1024).toStringAsFixed(1)}MB',
    );

    final videoIndex = meta.findVideoFileIndex();
    if (videoIndex == null) {
      _setError('种子中未找到视频文件');
      return null;
    }

    debugPrint('[TorrentEngine] 目标视频: ${meta.files[videoIndex]}');

    _pieceManager = PieceManager(metadata: meta, targetFileIndex: videoIndex);

    _pieceManager!.onProgress = (_, _) {
      if (!_readyNotified && _pieceManager!.isReadyToPlay) {
        _readyNotified = true;
      }
      onChanged?.call();
    };
    _pieceManager!.onPieceCompleted = (pieceIndex) {
      for (final peer in _peers) {
        peer.announcePiece(pieceIndex);
      }
      if (_pieceManager?.isComplete == true) {
        _setState(TorrentState.seeding);
      }
      onChanged?.call();
    };

    final pm = _pieceManager!;
    await _streamServer.start(pm);
    if (_disposed) {
      await _streamServer.stop();
      return null;
    }
    await _startPeerListener(meta, pm);
    if (_disposed) return null;

    _setState(TorrentState.connecting);
    final peerCount = await _connectToPeers();
    if (_disposed) return null;

    // Tracker peer lists routinely contain stale endpoints. Keep the local
    // stream alive and re-announce during the service's buffer window instead
    // of turning one unsuccessful handshake batch into a fatal error.
    _peerCheckTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkPeers(),
    );

    if (_pieceManager?.isComplete == true) {
      _setState(TorrentState.seeding);
    } else if (peerCount > 0) {
      _setState(TorrentState.downloading);
    }
    return _streamServer.streamUrl;
  }

  Future<int> _connectToPeers({String? event}) async {
    final meta = _metadata;
    if (meta == null) return 0;
    final pm = _pieceManager;
    if (pm == null || _isConnectingPeers) return 0;

    _isConnectingPeers = true;
    try {
      final announce = await _tracker.announceMetadata(
        metadata: meta,
        downloaded: pm.torrentDownloadedBytes,
        uploaded: _totalUploadedBytes(),
        port: _listenPort,
        event: event,
      );
      if (_disposed) return 0;
      _scheduleAnnounce(announce.interval);
      final peers = announce.peers;
      debugPrint('[TorrentEngine] 从 tracker 获取到 ${peers.length} 个 peer');

      final freeSlots = _maxPeers - _peers.length;
      if (freeSlots <= 0) return 0;

      final candidates = peers
          .where((addr) => !_peers.any((peer) => peer.address == addr))
          .take(freeSlots)
          .toList(growable: false);
      if (candidates.isEmpty) return 0;

      var nextCandidate = 0;
      var connectedCount = 0;

      Future<void> connectWorker() async {
        while (!_disposed &&
            nextCandidate < candidates.length &&
            _peers.length < _maxPeers) {
          final addr = candidates[nextCandidate++];
          final peer = PeerConnection(
            address: addr,
            infoHash: meta.infoHash,
            peerId: TrackerClient.peerId,
            pieceManager: pm,
            onUploaded: _recordUploaded,
          );

          _connectingPeers.add(peer);
          final connected = await peer.connect();
          _connectingPeers.remove(peer);
          if (!connected ||
              _metadata != meta ||
              _pieceManager != pm ||
              _peers.length >= _maxPeers ||
              _peers.any((item) => item.address == addr)) {
            peer.disconnect();
            continue;
          }

          _peers.add(peer);
          connectedCount++;
          peer.fillRequestPipeline();
        }
      }

      await Future.wait([
        for (var i = 0; i < min(8, candidates.length); i++) connectWorker(),
      ]);
      if (connectedCount > 0 && _state == TorrentState.connecting) {
        _setState(TorrentState.downloading);
      }
      return connectedCount;
    } catch (e) {
      debugPrint('[TorrentEngine] Tracker announce 失败: $e');
      return 0;
    } finally {
      _isConnectingPeers = false;
    }
  }

  void _scheduleAnnounce(Duration? interval) {
    _announceTimer?.cancel();
    _announceTimer = _disposed || interval == null
        ? null
        : Timer(interval, () => unawaited(_connectToPeers()));
  }

  Future<void> _startPeerListener(
    TorrentMetadata metadata,
    PieceManager pieceManager,
  ) async {
    await _peerServer?.close();
    _peerServer = null;
    _listenPort = TrackerClient.defaultListenPort;

    for (final port in const [TrackerClient.defaultListenPort, 0]) {
      try {
        final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        if (_disposed) {
          await server.close();
          return;
        }
        _peerServer = server;
        _listenPort = server.port;
        server.listen(
          (socket) =>
              unawaited(_acceptIncomingPeer(socket, metadata, pieceManager)),
          onError: (e) => debugPrint('[TorrentEngine] Peer 监听错误: $e'),
        );
        debugPrint('[TorrentEngine] Peer 监听端口: $_listenPort');
        return;
      } catch (e) {
        if (port != 0) {
          debugPrint('[TorrentEngine] 监听 $port 失败，尝试随机端口: $e');
        }
      }
    }
  }

  Future<void> _acceptIncomingPeer(
    Socket socket,
    TorrentMetadata metadata,
    PieceManager pieceManager,
  ) async {
    if (_peers.length >= _maxPeers || _metadata != metadata) {
      socket.destroy();
      return;
    }

    final addr = PeerAddress(socket.remoteAddress.address, socket.remotePort);
    final peer = PeerConnection(
      address: addr,
      infoHash: metadata.infoHash,
      peerId: TrackerClient.peerId,
      pieceManager: pieceManager,
      onUploaded: _recordUploaded,
    );
    _connectingPeers.add(peer);
    final accepted = await peer.accept(socket);
    _connectingPeers.remove(peer);
    if (!accepted ||
        _metadata != metadata ||
        _pieceManager != pieceManager ||
        _peers.length >= _maxPeers) {
      peer.disconnect();
      return;
    }
    _peers.add(peer);
    if (_state == TorrentState.connecting) {
      _setState(TorrentState.downloading);
    }
    peer.fillRequestPipeline();
  }

  void _checkPeers() {
    _peers.removeWhere((peer) {
      if (!peer.isConnected) {
        peer.disconnect();
        return true;
      }
      if (!peer.isChoked) peer.fillRequestPipeline();
      return false;
    });

    if (kDebugMode) {
      final pm = _pieceManager;
      if (pm != null) {
        final chokedCount = _peers.where((p) => p.isChoked).length;
        debugPrint(
          '[TorrentEngine] Peers: ${_peers.length} (已解锁:${_peers.length - chokedCount}, 被锁:$chokedCount), '
          '已下载: ${(pm.downloadedBytes / 1024).toStringAsFixed(0)}KB, '
          '进度: ${(pm.progress * 100).toStringAsFixed(1)}%, '
          '连续: ${(pm.contiguousBytes / 1024).toStringAsFixed(0)}KB',
        );
      }
    }

    if (_peers.length < 5) unawaited(_connectToPeers());
    if (_pieceManager?.isComplete == true) {
      _setState(TorrentState.seeding);
    }
  }

  Future<TorrentMetadata?> _fetchMetadataViaPeers(MagnetLink magnet) async {
    _setState(TorrentState.connecting);
    final announce = await _tracker.announceFromMagnet(
      magnet: magnet,
      port: _listenPort,
    );
    final peers = announce.peers;
    debugPrint('[TorrentEngine] BEP 9 metadata 候选 peer: ${peers.length}');
    if (_disposed || peers.isEmpty) return null;

    final completer = Completer<TorrentMetadata?>();
    final infoHash = magnet.infoHashBytes;
    final limit = min(peers.length, 24);
    final workerCount = min(limit, 6);
    var next = 0;
    var activeWorkers = workerCount;

    Future<void> worker() async {
      while (!_disposed && !completer.isCompleted) {
        final index = next++;
        if (index >= limit) break;
        try {
          final peer = MetadataPeerConnection(
            address: peers[index],
            infoHash: infoHash,
            peerId: TrackerClient.peerId,
          );
          _metadataPeers.add(peer);
          final infoBytes = await peer.fetch(
            timeout: const Duration(seconds: 10),
          );
          _metadataPeers.remove(peer);
          if (infoBytes == null || completer.isCompleted) continue;
          final metadata = TorrentMetadata.fromInfoBytes(
            infoBytes,
            trackers: magnet.trackers,
          );
          if (metadata.infoHashHex == magnet.infoHash) {
            completer.complete(metadata);
            return;
          }
        } catch (_) {}
      }
      activeWorkers--;
      if (activeWorkers == 0 && !completer.isCompleted) {
        completer.complete(null);
      }
    }

    for (var i = 0; i < workerCount; i++) {
      unawaited(worker());
    }
    final timer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) completer.complete(null);
    });
    try {
      return await Future.any([
        completer.future,
        _stopped.future.then((_) => null),
      ]);
    } finally {
      timer.cancel();
      for (final peer in _metadataPeers.toList()) {
        peer.disconnect();
      }
    }
  }

  Future<TorrentMetadata?> _fetchMetadataFromExactSources(
    MagnetLink magnet,
  ) async {
    for (final url in magnet.exactSources) {
      if (_disposed || _cancelToken.isCancelled) return null;
      try {
        final response = await _dio.get<List<int>>(
          url,
          cancelToken: _cancelToken,
        );
        if (response.statusCode != 200 || response.data == null) continue;
        final metadata = TorrentMetadata.fromBytes(
          _responseBytes(response.data!),
        );
        if (metadata.infoHashHex == magnet.infoHash) return metadata;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  void _setState(TorrentState newState) {
    if (_disposed || _state == newState) return;
    _state = newState;
    onChanged?.call();
  }

  void _setError(String message) {
    _errorMessage = message;
    _setState(TorrentState.error);
    debugPrint('[TorrentEngine] 错误: $message');
  }

  /// 停止下载并清理资源
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    _disposed = true;
    _stopped.complete();
    _cancelToken.cancel();
    _dio.close(force: true);
    _tracker.dispose();
    final metadata = _metadata;
    final pm = _pieceManager;
    final stoppedTracker = TrackerClient();
    final stoppedAnnounce = metadata == null || pm == null
        ? Future<void>.value()
        : stoppedTracker
              .announceMetadata(
                metadata: metadata,
                downloaded: pm.torrentDownloadedBytes,
                uploaded: _totalUploadedBytes(),
                port: _listenPort,
                event: 'stopped',
              )
              .then<void>((_) {});
    final stopDeadline = Timer(
      const Duration(seconds: 2),
      stoppedTracker.dispose,
    );
    for (final peer in _metadataPeers.toList()) {
      peer.disconnect();
    }
    for (final peer in _connectingPeers.toList()) {
      peer.disconnect();
    }
    _metadataPeers.clear();
    _connectingPeers.clear();
    _announceTimer?.cancel();
    _peerCheckTimer?.cancel();
    _announceTimer = null;
    _peerCheckTimer = null;
    await _peerServer?.close();
    _peerServer = null;
    _listenPort = TrackerClient.defaultListenPort;
    _isConnectingPeers = false;

    for (final peer in _peers) {
      peer.disconnect();
    }
    _peers.clear();

    await _streamServer.stop();
    _pieceManager?.dispose();
    _pieceManager = null;
    _metadata = null;
    _readyNotified = false;
    _uploadedBytes = 0;
    _state = TorrentState.idle;
    try {
      await stoppedAnnounce;
    } finally {
      stopDeadline.cancel();
      stoppedTracker.dispose();
    }
  }

  /// 更新速度统计（从 getStats 中分离，消除 getter 副作用）
  void _updateSpeed() {
    final now = _speedClock.elapsedMilliseconds;
    final elapsed = now - _lastSpeedAtMs;
    if (elapsed < 1000) return;

    final currentBytes = _pieceManager?.torrentDownloadedBytes ?? 0;
    final totalUploaded = _totalUploadedBytes();
    final seconds = elapsed / 1000;
    _downloadSpeed = ((currentBytes - _lastSpeedBytes) / seconds).clamp(
      0.0,
      double.infinity,
    );
    _uploadSpeed = ((totalUploaded - _lastUploadBytes) / seconds).clamp(
      0.0,
      double.infinity,
    );
    _lastSpeedBytes = currentBytes;
    _lastUploadBytes = totalUploaded;
    _lastSpeedAtMs = now;
  }

  /// 获取当前下载统计（强类型）
  TorrentStats getStats() {
    _updateSpeed();

    final pm = _pieceManager;
    final targetFile = pm?.targetFile;

    return TorrentStats(
      state: _state,
      peers: _peers.length,
      progress: pm?.progress ?? 0.0,
      downloadedBytes: pm?.downloadedBytes ?? 0,
      uploadedBytes: _totalUploadedBytes(),
      totalBytes: targetFile?.length ?? 0,
      contiguousBytes: pm?.contiguousBytes ?? 0,
      bufferRequiredBytes:
          pm?.bufferRequiredBytes ??
          min(_minBufferBytes, targetFile?.length ?? _minBufferBytes),
      readyToPlay: pm?.isReadyToPlay ?? false,
      downloadSpeed: _downloadSpeed,
      uploadSpeed: _uploadSpeed,
      errorMessage: _errorMessage,
      firstPiece: pm?.firstPiece ?? 0,
      lastPiece: pm?.lastPiece ?? -1,
      pieceStates: pm?.pieceStates ?? const <PieceState>[],
    );
  }

  static Uint8List _responseBytes(List<int> bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  int _totalUploadedBytes() {
    return _uploadedBytes;
  }

  void _recordUploaded(int bytes) {
    if (bytes <= 0) return;
    _uploadedBytes += bytes;
  }
}
