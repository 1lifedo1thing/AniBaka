import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/api/post.dart';
import 'package:baka/core/app_storage.dart';
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
/// 负责视频数据管理、适配器源管理、集数切换、进度管理、弹幕数据获取、BGM 信息等。
class PlaybackContent {
  static const String _prefetchedPlaybackKey = '_prefetchedPlayback';

  static bool isEpisodeWatched(String videoId, int episodeIndex) =>
      _readProgress('${videoId}_${episodeIndex}_1').inSeconds > 30;

  static Duration _readProgress(String key) {
    final progress = AppStorage.videoProgressBox.get(key);
    return Duration(milliseconds: progress?['positionMs'] as int? ?? 0);
  }

  static void storePrefetchedPlaybackMedia(
    Map data, {
    required int episodeIndex,
    required int lineIndex,
    required String episodeId,
    required String url,
    required Map<String, String> httpHeaders,
  }) {
    data[_prefetchedPlaybackKey] = PrefetchedMedia(
      source: data['source'] as String? ?? '',
      episodeIndex: episodeIndex,
      lineIndex: lineIndex,
      episodeId: episodeId,
      url: url,
      httpHeaders: httpHeaders,
      resolvedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static void clearPrefetchFrom(Map data) {
    data.remove(_prefetchedPlaybackKey);
  }

  void clearPrefetchedPlaybackMedia() {
    request.prefetched = null;
    clearPrefetchFrom(data);
  }

  PlaybackContent({
    required this.request,
    required this.sources,
    required this.collections,
    required this.history,
    this.posIndex,
  }) : data = request.metadata,
       videoList = request.episodes,
       currPlayIndex = request.episodeIndex,
       currUrl = request.lineIndex,
       sourceNames = request.sourceNames {
    if (!isLocalSource) {
      bgmInfo = BgmUtils.readFromData(data);
      bgmDetailData = BgmUtils.asMap(data['bgmDetailData']);
      final embeddedEpisodes = bgmDetailData?['episodes'];
      if (embeddedEpisodes is List) {
        bgmEpisodes = BgmUtils.asMapList(embeddedEpisodes);
        _bgmEpisodesLoaded = true;
      }
      BgmUtils.normalizeCoverImage(data, bgmInfo: bgmInfo);
    }
  }

  final TorrentService torrent = TorrentService();
  final PlaybackRequest request;
  final SourceAdapterService sources;
  final CollectionRepository collections;
  final HistoryRepository history;
  final Map<String, dynamic> data;
  final int? posIndex;

  List<PlaybackEpisode> videoList;
  int currPlayIndex, currUrl;
  List<String>? sourceNames;

  bool get isLocalSource => data['source']?.toString() == '_local';
  bool get isAdapter {
    final source = data['source']?.toString();
    return !isLocalSource && AdapterRegistry.isAdapterSource(source);
  }

  String? get localFilePath {
    if (isLocalSource && videoList.isNotEmpty) {
      final item = currentVideoItem;
      if (item != null && item.lines.isNotEmpty) {
        return item.lineAt(currUrl) ?? item.lines.first;
      }
    }
    return data['localFilePath'] as String?;
  }

  String? get danmakuPath => data['danmakuPath'] as String?;
  Map<String, String>? get localHttpHeaders =>
      data['httpHeaders'] as Map<String, String>?;

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
  String? get coverImageUrl =>
      BgmUtils.resolveCoverImage(data, bgmInfo: bgmInfo);

  Map<String, dynamic> buildSourceSeedData() {
    final subjectId = bgmInfo.subjectId;
    if (subjectId != null) data['bgmId'] = subjectId;
    final score = bgmInfo.score;
    if (score != null) data['score'] = score;
    final cover = coverImageUrl;
    if (cover != null && cover.isNotEmpty) data['bgmImageUrl'] = cover;
    final detail = bgmDetailData;
    if (detail != null) data['bgmDetailData'] = detail;
    return data;
  }

  String get logoUrl => AnimeDetailViewData.resolveLogoUrl(data);

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
    final lineCount = videoList[normalizedEpisodeIndex].lineCount;
    return (
      episodeIndex: normalizedEpisodeIndex,
      lineIndex: (lineCount <= 0 || preferred < 1 || preferred > lineCount)
          ? 1
          : preferred,
    );
  }

  void applySelection(({int episodeIndex, int lineIndex}) selection) {
    currPlayIndex = selection.episodeIndex;
    currUrl = selection.lineIndex;
    data['currPlayIndex'] = currPlayIndex;
    data['currUrl'] = currUrl;
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
    videoList = nextVideoList;
    data.remove('videos');
    data['videoList'] = nextVideoList;
    if (sourceNames != null) {
      this.sourceNames = sourceNames;
      data['sourceNames'] = sourceNames;
    }
    applySelection(
      normalizeSelection(
        preferredEpisodeIndex ?? currPlayIndex,
        preferredLineIndex ?? currUrl,
      ),
    );
  }

  Future<void> loadDetail() async {
    if (isLocalSource) {
      final existingVideos = data['videoList'];
      if (existingVideos is List<PlaybackEpisode> && existingVideos.isNotEmpty) {
        videoList = existingVideos;
      } else if (localFilePath != null) {
        videoList = [
          PlaybackEpisode(title: currentEpisodeTitle, lines: [localFilePath!]),
        ];
      }
      final preferred = posIndex ?? BgmUtils.toInt(data['currPlayIndex']) ?? 0;
      applySelection(normalizeSelection(preferred, data['currUrl']));
      return;
    }

    final explicitEpisodeIndex = posIndex ?? data['currPlayIndex'];
    final explicitLineIndex = data['currUrl'];

    if (!isAdapter) {
      final postId = int.tryParse(data['id']?.toString() ?? '');
      if (postId != null && postId > 0) {
        try {
          final response = await getPostDetail(postId);
          if (response.isNotEmpty) {
            data.addAll(response);
            videoList = PlaybackEpisodeCatalog.episodesOf(
              data,
              mergeDuplicateTitles: true,
            );
          }
        } catch (e) {
          debugPrint('[PlaybackContent] Failed to load post detail: $e');
        }
      }
    }

    final remembered = history.getResumeSelection(data);
    final initialEpisodeIndex =
        int.tryParse(
          (explicitEpisodeIndex ?? remembered?.episodeIndex ?? currPlayIndex)
              .toString(),
        ) ??
        0;
    final initialLineIndex =
        int.tryParse(
          (explicitLineIndex ?? remembered?.lineIndex ?? currUrl).toString(),
        ) ??
        1;

    syncVideoData(
      videoList,
      sourceNames: (data['sourceNames'] as List?)?.cast<String>(),
      preferredEpisodeIndex: initialEpisodeIndex,
      preferredLineIndex: initialLineIndex,
    );
  }

  Future<AdapterBase> prepareAdapterSource() async {
    await sources.init();
    final source = data['source']?.toString();
    final adapter = sources.adapterFor(source ?? '');
    if (adapter == null) throw Exception('不支持的源类型: $source');

    data['sourceUrl'] ??= adapter.baseUrl;
    data['sourceDisplayName'] ??= adapter.name;

    if (videoList.isEmpty || sourceNames == null) {
      final seriesUrl = data['seriesUrl'] ?? data['id'].toString();
      final catalog = await adapter.getPlaybackCatalog(seriesUrl.toString());
      if (catalog.isEmpty) throw Exception('无法获取剧集信息');
      syncVideoData(catalog.episodes, sourceNames: catalog.sourceNames);
    }
    return adapter;
  }

  String get currentEpisodeId => currentVideoItem?.lineAt(currUrl) ?? '';

  Future<({String url, Map<String, String> httpHeaders})> resolveAdapterPlaybackMedia(
    AdapterBase adapter,
    String episodeId, {
    Duration torrentBufferTimeout = TorrentService.defaultBufferTimeout,
    bool preferPrefetch = true,
  }) async {
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
          storePrefetchedPlaybackMedia(
            data,
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

    final streamUrl = await torrent.resolvePlaybackUrl(
      media.url,
      bufferTimeout: torrentBufferTimeout,
    );
    return (url: streamUrl, httpHeaders: const <String, String>{});
  }

  Future<int> startAdapterPlaybackKeepAlive(
    AdapterBase adapter,
    String mediaUrl,
  ) async {
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

  void adoptPlaybackData(Map from) {
    final v = from[_prefetchedPlaybackKey] as PrefetchedMedia?;
    clearPrefetchedPlaybackMedia();
    request.prefetched = v;
    if (v != null) data[_prefetchedPlaybackKey] = v;

    data.addAll(from.cast<String, dynamic>());

    final episodes = PlaybackEpisodeCatalog.episodesOf(
      data,
      mergeDuplicateTitles: true,
    );
    if (episodes.isNotEmpty) {
      syncVideoData(
        episodes,
        sourceNames: (data['sourceNames'] as List?)?.cast<String>(),
        preferredEpisodeIndex:
            BgmUtils.toInt(from['currPlayIndex']) ?? currPlayIndex,
        preferredLineIndex: BgmUtils.toInt(from['currUrl']) ?? currUrl,
      );
    }
  }

  ({String url, Map<String, String> httpHeaders})? _readPrefetchedPlaybackMedia(
    String episodeId, {
    int? episodeIndex,
  }) {
    final media =
        request.prefetched ?? data[_prefetchedPlaybackKey] as PrefetchedMedia?;
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
    try {
      if (episodeIndex < 0 || episodeIndex >= videoList.length) return null;
      final item = videoList[episodeIndex];
      final episodeId = item.lineAt(currUrl) ?? item.lines.firstOrNull;
      if (episodeId == null) return null;

      if (isLocalSource) return episodeId;

      if (isAdapter) {
        final adapter = sources.adapterFor(data['source']?.toString() ?? '');
        if (adapter == null) return null;
        final resolvedUrl =
            _readPrefetchedPlaybackMedia(
              episodeId,
              episodeIndex: episodeIndex,
            )?.url ??
            await adapter.resolveDownloadUrl(episodeId);
        return resolvedUrl.isEmpty ? null : resolvedUrl;
      }

      final response = await getPlayUrl(episodeId).timeout(const Duration(seconds: 15));
      if (response.isEmpty) return null;
      final jsonData = jsonDecode(response) as Map<String, dynamic>;
      return (jsonData['data'] as Map<String, dynamic>?)?['url'] as String?;
    } catch (e) {
      debugPrint('解析第 ${episodeIndex + 1} 集下载地址失败: $e');
      return null;
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
      BgmUtils.normalizeCoverImage(data, bgmInfo: bgmInfo);
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
      if (resolvedLogo.isNotEmpty) data['logoUrl'] = resolvedLogo;
      final airDate = BgmUtils.formatPlainDate(detail['date']);
      if (airDate != null) data['airDate'] = airDate;
      return detail;
    } catch (e) {
      debugPrint('获取 BGM 放映信息失败: $e');
      _bgmDetailFuture = null;
      return null;
    }
  }

  Future<List<DanmakuItem>> fetchDanmakuData(int episodeIndex) async {
    final title = data['title']?.toString() ?? '';
    final info = await ensureBgmInfo();
    final bgmId = info.subjectId;
    if (bgmId == null) return const [];

    return DanmakuController.fetchDanmaku(
      subjectId: bgmId,
      episodeIndex: episodeIndex + 1,
      titles: BgmUtils.buildSearchTitles([title]),
    );
  }

  Future<void> saveProgress(
    Duration position,
    bool rememberLastPosition,
  ) async {
    if (!rememberLastPosition) return;
    await AppStorage.videoProgressBox.put(videoKey, {
      'positionMs': position.inMilliseconds,
      'updateTime': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Duration getSavedProgress() => _readProgress(videoKey);

  Future<void> rememberCurrentEpisode() async {
    if (isLocalSource || videoList.isEmpty) return;
    final bgmId = bgmInfo.subjectId;
    if (bgmId != null) data['bgmId'] ??= bgmId;
    await history.rememberEpisode(
      videoData: data,
      episodeIndex: currPlayIndex,
      urlIndex: currUrl,
    );
  }

  Future<String?> readLocalDanmakuFile(String videoPath) async {
    final explicitPath = danmakuPath;
    if (explicitPath != null) {
      final file = File(explicitPath);
      if (await file.exists()) return file.readAsString();
    }
    if (videoPath.startsWith('http://') || videoPath.startsWith('https://')) {
      return null;
    }
    final videoFile = File(videoPath);
    final danmakuFile = File(
      '${videoFile.parent.path}${Platform.pathSeparator}${videoFile.uri.pathSegments.last}_danmaku.json',
    );
    if (await danmakuFile.exists()) return danmakuFile.readAsString();
    return null;
  }

  Future<void> saveHistory({
    required int positionMs,
    required int durationMs,
  }) async {
    if (isLocalSource) return;
    final cover = coverImageUrl;
    if (cover != null && cover.isNotEmpty) data['bgmImageUrl'] ??= cover;
    final bgmId = bgmInfo.subjectId;
    if (bgmId != null) data['bgmId'] ??= bgmId;

    await history.saveHistory(
      videoData: data,
      episodeIndex: currPlayIndex,
      positionMs: positionMs,
      durationMs: durationMs,
      urlIndex: currUrl,
    );
  }

  int? get validPostId {
    final postId = BgmUtils.toInt(data['id']);
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

  Future<void> dispose() async {
    stopAdapterPlaybackKeepAlive();
    await torrent.stopStream();
  }
}
