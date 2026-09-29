import 'package:baka/source/runtime/source_operation.dart';
import 'dart:async';
import 'package:baka/utils/title_matcher.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/utils/json_values.dart';

import 'package:flutter/foundation.dart';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/api/playback.dart';
import 'package:baka/models/anime_detail_view_data.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/utils/bgm_utils.dart';

/// 播放器业务逻辑服务
///
/// 持有当前播放会话、剧集/线路选择和资源解析；持久化由 Repository 持有。
class PlaybackContent {
  void clearPrefetchedPlaybackMedia() => request.prefetched = null;

  PlaybackContent({
    required PlaybackRequest request,
    required this.sources,
    required this.collections,
    required this.history,
    this.posIndex,
  }) : _request = request.copyWith() {
    if (!isLocalSource) {
      bgmInfo = BgmInfo.fromData(data);
      bgmDetailData = asMap(data['bgmDetailData']);
      final embeddedEpisodes = bgmDetailData?['episodes'];
      if (embeddedEpisodes is List) {
        bgmEpisodes = asMapList(embeddedEpisodes);
        _bgmEpisodesLoaded = true;
      }
    }
  }

  final TorrentService torrent = TorrentService();
  PlaybackRequest _request;
  PlaybackRequest get request => _request;
  SourceOperation _lifetime = SourceOperation();
  bool _disposed = false;
  final SourceAdapterService sources;
  final CollectionRepository collections;
  final HistoryRepository history;
  Map<String, dynamic> get data => request.metadata;
  final int? posIndex;

  List<PlaybackEpisode> get videoList => request.episodes;
  int get currPlayIndex => request.episodeIndex ?? 0;
  int get currUrl => request.lineIndex ?? 1;
  List<String>? get sourceNames => request.sourceNames;

  bool get isLocalSource => request.source == '_local';
  bool get isAdapter {
    final source = request.source;
    return !isLocalSource && AdapterRegistry.isAdapterSource(source);
  }

  String? get localFilePath {
    if (isLocalSource && videoList.isNotEmpty) {
      final item = currentVideoItem;
      if (item != null && item.lines.isNotEmpty) {
        return item.lineAt(currUrl) ??
            item.lineAt(item.availableLineIndexes.firstOrNull ?? 1) ??
            '';
      }
    }
    return data['localFilePath'] as String?;
  }

  String? get danmakuPath => data['danmakuPath'] as String?;
  Map<String, String>? get localHttpHeaders => request.httpHeaders;

  BgmInfo bgmInfo = const BgmInfo();
  Map<String, dynamic>? bgmDetailData;
  List<Map<String, dynamic>> bgmEpisodes = const [];
  bool _bgmEpisodesLoaded = false;
  Future<BgmInfo>? _bgmInfoFuture;
  Future<Map<String, dynamic>?>? _bgmDetailFuture;
  AnimeCollection? collection;
  Future<AnimeCollection?>? _collectionFuture;

  AdapterBase? _playbackKeepAliveAdapter;
  int _playbackKeepAliveGeneration = 0;

  PlaybackEpisode? get currentVideoItem =>
      currPlayIndex >= 0 && currPlayIndex < videoList.length
      ? videoList[currPlayIndex]
      : null;

  String get currentEpisodeTitle {
    if (isLocalSource) {
      final item = currentVideoItem;
      if (item != null && item.title.isNotEmpty) return item.title;

      final localEpisodeTitle = data['episodeTitle']?.toString().trim();
      if (localEpisodeTitle != null && localEpisodeTitle.isNotEmpty) {
        return localEpisodeTitle;
      }

      final path = localFilePath;
      if (path != null && path.isNotEmpty) {
        final slash = path.lastIndexOf('/');
        final backslash = path.lastIndexOf('\\');
        final separator = slash > backslash ? slash : backslash;
        return separator < 0 ? path : path.substring(separator + 1);
      }
    }
    return currentVideoItem?.title ?? '';
  }

  String? get bgmEpisodeTitle {
    if (currPlayIndex < 0 || currPlayIndex >= bgmEpisodes.length) return null;
    final ep = bgmEpisodes[currPlayIndex];
    return (ep['name_cn']?.toString().isNotEmpty == true
            ? ep['name_cn']
            : ep['name'])
        ?.toString();
  }

  String get title => data['title']?.toString() ?? '';
  String? _searchTitle;
  List<String> _searchTitles = const [];

  List<String> get searchTitles {
    final current = title;
    if (_searchTitle != current) {
      _searchTitle = current;
      _searchTitles = buildSearchTitles([current]);
    }
    return _searchTitles;
  }

  String? get coverImageUrl => resolveCoverImage(data, bgmInfo: bgmInfo);

  String? _logoUrl;
  String? _airDate;
  String get logoUrl => _logoUrl ?? AnimeDetailViewData.resolveLogoUrl(data);

  /// A fresh projection for old views/search sheets; never shared writable state.
  Map<String, dynamic> buildSourceSeedData() => {
    ...data,
    'source': request.source,
    if (bgmInfo.subjectId != null) 'bgmId': bgmInfo.subjectId,
    if (bgmInfo.score != null) 'score': bgmInfo.score,
    if (coverImageUrl != null) 'bgmImageUrl': coverImageUrl,
    if (bgmDetailData != null) 'bgmDetailData': bgmDetailData,
    if (logoUrl.isNotEmpty) 'logoUrl': logoUrl,
    if (_airDate != null) 'airDate': _airDate,
  };

  Map<String, dynamic> buildLegacyData() => {
    ...data,
    'source': request.source,
    'videoList': videoList,
    'sourceNames': sourceNames,
    'currPlayIndex': currPlayIndex,
    'currUrl': currUrl,
    if (request.httpHeaders != null) 'httpHeaders': request.httpHeaders,
    if (bgmInfo.subjectId != null) 'bgmId': bgmInfo.subjectId,
    if (bgmInfo.score != null) 'score': bgmInfo.score,
    if (coverImageUrl != null) 'bgmImageUrl': coverImageUrl,
    if (bgmDetailData != null) 'bgmDetailData': bgmDetailData,
    if (logoUrl.isNotEmpty) 'logoUrl': logoUrl,
    if (_airDate != null) 'airDate': _airDate,
  };

  PlaybackMediaInfo get initialMediaInfo => PlaybackMediaInfo(
    title: title,
    imageUrl: coverImageUrl ?? '',
    logoUrl: logoUrl,
  );

  PlaybackMediaInfo get currentMediaInfo {
    final episodeTitle = bgmEpisodeTitle;
    return PlaybackMediaInfo(
      title: title,
      episode: episodeTitle?.isNotEmpty == true
          ? episodeTitle!
          : currentEpisodeTitle,
      imageUrl: coverImageUrl ?? '',
      logoUrl: logoUrl,
      episodeIndex: currPlayIndex,
      totalEpisodes: videoList.length,
    );
  }

  String get videoKey => isLocalSource
      ? localFilePath ?? ''
      : "${data['id']}_${currPlayIndex}_$currUrl";

  ({int episodeIndex, int lineIndex}) normalizeSelection(
    int episodeIndex, [
    int? lineIndex,
  ]) {
    if (videoList.isEmpty) {
      return (episodeIndex: 0, lineIndex: 1);
    }
    final normalizedEpisodeIndex = episodeIndex.clamp(0, videoList.length - 1);
    final preferred = lineIndex ?? currUrl;
    final episode = videoList[normalizedEpisodeIndex];
    return (
      episodeIndex: normalizedEpisodeIndex,
      lineIndex: episode.lineAt(preferred) != null
          ? preferred
          : episode.availableLineIndexes.firstOrNull ?? 1,
    );
  }

  void applySelection(({int episodeIndex, int lineIndex}) selection) {
    request.episodeIndex = selection.episodeIndex;
    request.lineIndex = selection.lineIndex;
    if (_readPrefetchedPlaybackMedia(currentEpisodeId) == null) {
      clearPrefetchedPlaybackMedia();
    }
  }

  void syncVideoData(
    List<PlaybackEpisode> nextVideoList, {
    List<String>? sourceNames,
    int? preferredEpisodeIndex,
    int? preferredLineIndex,
  }) {
    _request = request.copyWith(
      episodes: nextVideoList,
      sourceNames: sourceNames,
    );
    applySelection(
      normalizeSelection(
        preferredEpisodeIndex ?? currPlayIndex,
        preferredLineIndex ?? currUrl,
      ),
    );
  }

  Future<void> loadDetail() async {
    if (isLocalSource) {
      if (videoList.isEmpty && localFilePath != null) {
        _request = request.copyWith(
          episodes: [
            PlaybackEpisode(
              title: currentEpisodeTitle,
              lines: [localFilePath!],
            ),
          ],
        );
      }
      final preferred = posIndex ?? currPlayIndex;
      applySelection(normalizeSelection(preferred, currUrl));
      return;
    }

    final explicitEpisodeIndex = posIndex ?? request.episodeIndex;
    final explicitLineIndex = request.lineIndex;

    if (!isAdapter) {
      final postId = int.tryParse(data['id']?.toString() ?? '');
      if (postId != null && postId > 0) {
        final lifetime = _lifetime;
        lifetime.token.throwIfCancelled();
        final abort = Completer<void>();
        final detach = lifetime.token.onCancel(abort.complete);
        try {
          final response = await getPostDetail(
            postId,
            abortTrigger: abort.future,
          );
          lifetime.token.throwIfCancelled();
          if (response.isNotEmpty) {
            final detail = PlaybackRequest.fromMap(response);
            _request = request.copyWith(
              episodes: detail.episodes,
              sourceNames: detail.sourceNames,
              metadata: {...data, ...detail.metadata},
            );
          }
        } catch (e) {
          if (lifetime.isCancelled || videoList.isEmpty) rethrow;
          debugPrint('[PlaybackContent] Failed to load post detail: $e');
        } finally {
          detach();
        }
      }
    }

    final remembered = history.getResumeSelection(
      request,
      bgmId: bgmInfo.subjectId,
    );
    syncVideoData(
      videoList,
      sourceNames: sourceNames,
      preferredEpisodeIndex:
          toInt(
            explicitEpisodeIndex ?? remembered?.episodeIndex ?? currPlayIndex,
          ) ??
          0,
      preferredLineIndex:
          toInt(explicitLineIndex ?? remembered?.lineIndex ?? currUrl) ?? 1,
    );
  }

  Future<AdapterBase> prepareAdapterSource() async {
    final operation = SourceOperation(
      parent: _lifetime,
      timeout: const Duration(seconds: 15),
    );
    final detach = SourceOperation.current?.token.onCancel(operation.cancel);
    try {
      return await operation.run(() async {
        final current = request;
        await sources.init();
        _lifetime.token.throwIfCancelled();
        SourceOperation.check();
        final source = current.source;
        final adapter = sources.adapterFor(source);
        if (adapter == null) throw Exception('不支持的源类型: $source');

        sources.retainPlayback(this, adapter);

        if (videoList.isEmpty || sourceNames == null) {
          final seriesUrl = data['seriesUrl'] ?? data['id'].toString();
          final catalog = await adapter.getPlaybackCatalog(
            seriesUrl.toString(),
          );
          _lifetime.token.throwIfCancelled();
          SourceOperation.check();
          if (!identical(current, request)) throw StateError('播放会话已变更');
          if (catalog.isEmpty) throw Exception('无法获取剧集信息');
          syncVideoData(catalog.episodes, sourceNames: catalog.sourceNames);
        }
        return adapter;
      });
    } finally {
      detach?.call();
      operation.close();
    }
  }

  String get currentEpisodeId => currentVideoItem?.lineAt(currUrl) ?? '';

  Future<({String url, Map<String, String> httpHeaders})>
  resolveAdapterPlaybackMedia(
    AdapterBase adapter,
    String episodeId, {
    Duration torrentBufferTimeout = TorrentService.defaultBufferTimeout,
    bool preferPrefetch = true,
  }) async {
    final operation = SourceOperation(parent: _lifetime);
    final detachOuter = SourceOperation.current?.token.onCancel(
      operation.cancel,
    );
    try {
      return await operation.run(() async {
        var media =
            (preferPrefetch ? _readPrefetchedPlaybackMedia(episodeId) : null) ??
            await adapter.resolvePlaybackMedia(episodeId);

        if (media.url.isEmpty) {
          clearPrefetchedPlaybackMedia();
          final episode = currentVideoItem;
          if (episode != null) {
            for (var line = 1; line <= episode.lines.length; line++) {
              if (line == currUrl) continue;
              final alternateId = episode.lineAt(line);
              if (alternateId == null || alternateId.isEmpty) continue;
              final alternate = await adapter.resolvePlaybackMedia(alternateId);
              if (alternate.url.isEmpty) continue;
              applySelection((episodeIndex: currPlayIndex, lineIndex: line));
              media = alternate;
              request.storePrefetched(
                episodeIndex: currPlayIndex,
                lineIndex: line,
                episodeId: alternateId,
                url: alternate.url,
                httpHeaders: alternate.httpHeaders,
              );
              break;
            }
          }
        }
        if (media.url.isEmpty || !TorrentService.isBtLink(media.url)) {
          return media;
        }

        final detach = SourceOperation.current?.token.onCancel(() {
          unawaited(torrent.stopStream());
        });
        final String streamUrl;
        try {
          streamUrl = await torrent.resolvePlaybackUrl(
            media.url,
            bufferTimeout: torrentBufferTimeout,
          );
        } finally {
          detach?.call();
        }
        return (url: streamUrl, httpHeaders: const <String, String>{});
      });
    } finally {
      detachOuter?.call();
      operation.close();
    }
  }

  Future<int> startAdapterPlaybackKeepAlive(
    AdapterBase adapter,
    String mediaUrl,
  ) async {
    _lifetime.token.throwIfCancelled();
    SourceOperation.check();
    sources.retainPlayback(this, adapter);
    final generation = ++_playbackKeepAliveGeneration;
    _playbackKeepAliveAdapter?.stopPlaybackKeepAlive();
    _playbackKeepAliveAdapter = adapter;
    await adapter.startPlaybackKeepAlive(mediaUrl);
    return generation;
  }

  void stopAdapterPlaybackKeepAlive([int? generation]) {
    if (generation != null && generation != _playbackKeepAliveGeneration) {
      return;
    }
    _playbackKeepAliveGeneration++;
    _playbackKeepAliveAdapter?.stopPlaybackKeepAlive();
    _playbackKeepAliveAdapter = null;
  }

  void adoptPlaybackRequest(PlaybackRequest next) {
    _lifetime.token.throwIfCancelled();
    _lifetime.cancel();
    _lifetime.close();
    _lifetime = SourceOperation();
    stopAdapterPlaybackKeepAlive();
    sources.releasePlayback(this);
    _request = next.copyWith();
    applySelection(normalizeSelection(currPlayIndex, currUrl));
  }

  ({String url, Map<String, String> httpHeaders})? _readPrefetchedPlaybackMedia(
    String episodeId, {
    int? episodeIndex,
  }) {
    final media = request.prefetched;
    if (media == null ||
        !media.matches(
          request.source,
          episodeIndex ?? currPlayIndex,
          currUrl,
          episodeId,
          DateTime.now().millisecondsSinceEpoch,
        )) {
      return null;
    }
    return (url: media.url, httpHeaders: media.httpHeaders);
  }

  Future<String?> resolveEpisodeUrl(int episodeIndex) async {
    final operation = SourceOperation(
      parent: _lifetime,
      timeout: const Duration(seconds: 15),
    );
    final detach = SourceOperation.current?.token.onCancel(operation.cancel);
    try {
      return await operation.run(() async {
        if (episodeIndex < 0 || episodeIndex >= videoList.length) return null;
        final item = videoList[episodeIndex];
        final episodeId =
            item.lineAt(currUrl) ??
            item.lineAt(item.availableLineIndexes.firstOrNull ?? 1);
        if (episodeId == null) return null;

        if (isLocalSource) return episodeId;

        if (isAdapter) {
          final adapter = sources.adapterFor(request.source);
          if (adapter == null) return null;
          final resolvedUrl =
              _readPrefetchedPlaybackMedia(
                episodeId,
                episodeIndex: episodeIndex,
              )?.url ??
              await adapter.resolveDownloadUrl(episodeId);
          return resolvedUrl.isEmpty ? null : resolvedUrl;
        }

        final abort = Completer<void>();
        final detach = operation.token.onCancel(() => abort.complete());
        try {
          return await getPlayUrl(episodeId, abortTrigger: abort.future);
        } finally {
          detach();
        }
      });
    } finally {
      detach?.call();
      operation.cancel();
      operation.close();
    }
  }

  Future<BgmInfo> ensureBgmInfo() {
    if (isLocalSource || bgmInfo.subjectId != null) {
      return Future.value(bgmInfo);
    }
    return _bgmInfoFuture ??= _loadBgmInfo();
  }

  Future<BgmInfo> _loadBgmInfo() async {
    try {
      bgmInfo = await resolveBgmFromData(data);
      return bgmInfo;
    } catch (_) {
      _bgmInfoFuture = null;
      return bgmInfo;
    }
  }

  Future<Map<String, dynamic>?> ensureBgmDetail() {
    if (isLocalSource) return Future.value(null);
    if (bgmDetailData != null && _bgmEpisodesLoaded && logoUrl.isNotEmpty) {
      return Future.value(bgmDetailData);
    }
    return _bgmDetailFuture ??= _loadBgmDetail();
  }

  Future<Map<String, dynamic>?> _loadBgmDetail() async {
    try {
      final subjectId = (await ensureBgmInfo()).subjectId;
      if (subjectId == null) return null;

      final detailFuture = bgmDetailData == null
          ? getBgmSubject(subjectId)
          : Future.value(bgmDetailData!);
      final episodesFuture = _bgmEpisodesLoaded
          ? Future.value(bgmEpisodes)
          : getBgmEpisodes(subjectId);
      final animeDetailFuture = logoUrl.isEmpty
          ? AniBakaApi.getAnimeDetail(subjectId).catchError((_) => null)
          : Future<Map<String, dynamic>?>.value(null);

      final result = await (
        detailFuture,
        episodesFuture,
        animeDetailFuture,
      ).wait;
      final detail = result.$1;
      bgmEpisodes = result.$2;
      final animeDetail = result.$3;
      _bgmEpisodesLoaded = true;

      bgmDetailData = detail;
      final resolvedLogo = AnimeDetailViewData.resolveLogoUrl(animeDetail);
      if (resolvedLogo.isNotEmpty) _logoUrl = resolvedLogo;
      final airDate = BgmUtils.formatPlainDate(detail['date']);
      if (airDate != null) _airDate = airDate;
      return detail;
    } catch (e) {
      debugPrint('获取 BGM 放映信息失败: $e');
      _bgmDetailFuture = null;
      return null;
    }
  }

  Future<List<DanmakuItem>> fetchDanmakuData(int episodeIndex) async {
    final lifetime = _lifetime;
    if (isLocalSource) {
      return DanmakuController.loadLocal(
        localFilePath,
        danmakuPath: danmakuPath,
      );
    }
    final info = await ensureBgmInfo();
    lifetime.token.throwIfCancelled();
    final bgmId = info.subjectId;
    if (bgmId == null) return const [];

    final abort = Completer<void>();
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    final detach = lifetime.token.onCancel(cancel);
    final detachOuter = SourceOperation.current?.token.onCancel(cancel);
    try {
      return await DanmakuController.fetchDanmaku(
        subjectId: bgmId,
        episodeIndex: episodeIndex + 1,
        titles: searchTitles,
        abortTrigger: abort.future,
      );
    } finally {
      detach();
      detachOuter?.call();
    }
  }

  int? get validPostId {
    final postId = toInt(data['id']);
    return postId != null && postId > 0 ? postId : null;
  }

  bool isFollow() =>
      CollectionStatus.fromValue(collection?.status) == CollectionStatus.doing;

  Future<AnimeCollection?> ensureCollectionStatus() {
    if (isLocalSource) return Future.value(collection);
    return _collectionFuture ??= _loadCollection();
  }

  Future<AnimeCollection?> _loadCollection() async {
    try {
      final bgmId = (await ensureBgmInfo()).subjectId;
      if (bgmId == null) return collection;
      final result = await collections.getByBgmId(bgmId);
      if (result != null) collection = result;
      return collection;
    } catch (e) {
      debugPrint('获取追番状态失败: $e');
      _collectionFuture = null;
      return collection;
    }
  }

  Future<String> toggleFollow() async {
    await Future.wait([
      ensureBgmInfo(),
      ensureBgmDetail(),
      ensureCollectionStatus(),
    ]);

    if (isFollow()) {
      final current = collection;
      if (current == null) return '操作失败';
      final bgmId = current.bgmId ?? bgmInfo.subjectId;
      final postId = current.postId ?? validPostId;
      final success = bgmId != null
          ? await collections.deleteByBgmId(bgmId)
          : postId != null
          ? await collections.delete(postId)
          : false;
      if (!success) throw Exception('取消追番失败');
      collection = null;
      return '已取消在看';
    }

    final detail = bgmDetailData;
    final epCount = videoList.isEmpty ? null : videoList.length;
    final result = await collections.addOrUpdate(
      AnimeCollection(
        postId: validPostId,
        bgmId: bgmInfo.subjectId,
        status: CollectionStatus.doing.value,
        epTotal: epCount,
        epWatched: epCount == null ? null : currPlayIndex + 1,
        postTitle: title,
        postCover: coverImageUrl,
        bgmImage: bgmInfo.imageUrl,
        bgmTitle:
            detail?['name_cn']?.toString() ??
            detail?['name']?.toString() ??
            title,
      ),
    );
    if (result == null) throw Exception('追番失败');
    collection = result;
    return '已加入在看';
  }

  Future<void>? _disposing;
  Future<void> dispose() => _disposing ??= _dispose();
  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lifetime.cancel();
    _lifetime.close();
    stopAdapterPlaybackKeepAlive();
    sources.releasePlayback(this);
    await torrent.dispose();
  }
}
