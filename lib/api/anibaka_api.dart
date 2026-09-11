import 'package:baka/api/api_config.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/play_history.dart';
import 'package:baka/models/watch_party.dart';

/// AniBaka v1 API 的唯一客户端入口。
final class AniBakaApi {
  AniBakaApi._();

  static String get _baseUrl => '${ApiConfig.host}/api/v1';

  /// 条目详情单条响应可达数十 KB（海报 / 剧照数组），做有界 LRU：
  /// 只保留最近 16 条、10 分钟内有效，避免长时间浏览把整份详情常驻内存。
  static final _animeDetails = RequestCache<int, Map<String, dynamic>?>(
    limit: 16,
    ttl: const Duration(minutes: 10),
    shouldCache: (value) => value != null,
  );

  /// 集截图按 (bgm_id / tmdb_id / tvdb_id, season, episode) 缓存。
  static final _episodeStills =
      RequestCache<
        ({int? bgmId, int? tmdbId, String? tvdbId, int season, int episode}),
        Map<String, dynamic>?
      >(
        limit: 16,
        ttl: const Duration(minutes: 10),
        shouldCache: (value) => value != null,
      );

  static Future<T?> _read<T>(
    Future<Map<String, dynamic>?> data,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final value = await data;
    return value == null ? null : parse(value);
  }

  static Future<bool> _deleted(String url) async =>
      ApiTransport.accepted(
        await apiTransport.deleteJson<Map<String, dynamic>>(url),
      );

  static Future<AnimeCollection?> saveCollection(AnimeCollection collection) =>
      _read(
        apiTransport.postData<Map<String, dynamic>>(
          '$_baseUrl/collection',
          collection.toJson(),
        ),
        AnimeCollection.fromJson,
      );

  static Future<CollectionListResponse?> getCollections({
    int page = 1,
    int pageSize = 20,
    int? status,
    int? bgmId,
  }) {
    final uri = Uri.parse('$_baseUrl/collection').replace(
      queryParameters: {
        'page': '$page',
        'page_size': '$pageSize',
        if (status != null) 'status': '$status',
        if (bgmId != null) 'bgm_id': '$bgmId',
      },
    );
    return _read(
      apiTransport.getData<Map<String, dynamic>>(uri.toString()),
      CollectionListResponse.fromJson,
    );
  }

  static Future<CollectionStats?> getCollectionStats() => _read(
    apiTransport.getData<Map<String, dynamic>>('$_baseUrl/collection/stats'),
    CollectionStats.fromJson,
  );

  static Future<AnimeCollection?> getCollectionByPostId(int postId) => _read(
    apiTransport.getData<Map<String, dynamic>>(
      '$_baseUrl/collection/post/$postId',
    ),
    AnimeCollection.fromJson,
  );

  static Future<AnimeCollection?> getCollectionByBgmId(int bgmId) => _read(
    apiTransport.getData<Map<String, dynamic>>('$_baseUrl/bgm-collection/$bgmId'),
    AnimeCollection.fromJson,
  );

  static Future<bool> deleteCollection(int postId) =>
      _deleted('$_baseUrl/collection/$postId');

  static Future<bool> deleteCollectionByBgmId(int bgmId) =>
      _deleted('$_baseUrl/bgm-collection/$bgmId');

  static Future<PlayHistory?> savePlayHistory(PlayHistory history) => _read(
    apiTransport.postData<Map<String, dynamic>>(
      '$_baseUrl/play-history',
      history.toJson(),
    ),
    PlayHistory.fromJson,
  );

  static Future<PlayHistoryListResponse?> getPlayHistory({int pageSize = 20}) =>
      _read(
        apiTransport.getData<Map<String, dynamic>>(
          '$_baseUrl/play-history?page_size=$pageSize',
        ),
        PlayHistoryListResponse.fromJson,
      );

  static Future<bool> clearPlayHistory() =>
      _deleted('$_baseUrl/play-history-clear');

  static Future<Map<String, dynamic>?> getAnimeDetail(int bgmId) =>
      _animeDetails.get(
        bgmId,
        () => apiTransport.getData<Map<String, dynamic>>(
          '$_baseUrl/anime/detail?bgm_id=$bgmId',
          notifyOnError: false,
        ),
      );

  static Future<Map<String, dynamic>?> getEpisodeStills({
    int? bgmId,
    int? tmdbId,
    String? tvdbId,
    int season = 1,
    int episode = 1,
  }) {
    final key = (
      bgmId: bgmId,
      tmdbId: tmdbId,
      tvdbId: tvdbId,
      season: season,
      episode: episode,
    );
    return _episodeStills.get(key, () {
      final uri = Uri.parse('$_baseUrl/anime/episode/stills').replace(
        queryParameters: {
          if (tmdbId != null && tmdbId > 0) 'tmdb_id': '$tmdbId',
          if (bgmId != null && bgmId > 0) 'bgm_id': '$bgmId',
          if (tvdbId != null && tvdbId.isNotEmpty) 'tvdb_id': tvdbId,
          'season': '$season',
          'ep': '$episode',
        },
      );
      return apiTransport.getData<Map<String, dynamic>>(
        uri.toString(),
        notifyOnError: false,
      );
    });
  }

  static String get _watchBaseUrl => '$_baseUrl/watch';

  static Future<WatchPartyInvite> createWatchRoom(WatchPartyMedia media) async =>
      WatchPartyInvite.fromJson(
        await _requiredData(
          apiTransport.postJson<Map<String, dynamic>>('$_watchBaseUrl/rooms', {
            'media': media.toJson(),
          }, notifyOnError: false),
          unavailable: '一起看服务暂时不可用',
          failed: '创建一起看房间失败',
        ),
      );

  static Future<List<WatchPartyInvite>> listWatchRooms() async {
    final data = await _requiredData(
      apiTransport.getJson<Map<String, dynamic>>(
        '$_watchBaseUrl/rooms',
        notifyOnError: false,
      ),
      unavailable: '一起看服务暂时不可用',
      failed: '获取一起看房间失败',
    );
    final rooms = data['rooms'] as List<dynamic>;
    return [
      for (final room in rooms)
        WatchPartyInvite.fromJson(room as Map<String, dynamic>),
    ];
  }

  static Future<WatchPartyInvite> getWatchInvite(String code) async =>
      WatchPartyInvite.fromJson(
        await _requiredData(
          apiTransport.getJson<Map<String, dynamic>>(
            '$_watchBaseUrl/invites/$code',
            notifyOnError: false,
          ),
          unavailable: '一起看服务暂时不可用',
          failed: '获取邀请失败',
        ),
      );

  static Future<String> joinWatchRoom(String code, String nickname) async {
    final data = await _requiredData(
      apiTransport.postJson<Map<String, dynamic>>(
        '$_watchBaseUrl/invites/$code/join',
        {'nickname': nickname},
        notifyOnError: false,
      ),
      unavailable: '一起看服务暂时不可用',
      failed: '加入一起看房间失败',
    );
    return data['websocketUrl'] as String;
  }

  static Future<void> closeWatchRoom(String roomId) => _requiredData(
    apiTransport.deleteJson<Map<String, dynamic>>('$_watchBaseUrl/rooms/$roomId'),
    unavailable: '无法结束房间',
    failed: '无法结束房间',
  ).then((_) {});


  static Future<Map<String, dynamic>> _requiredData(
    Future<Map<String, dynamic>?> request, {
    required String unavailable,
    required String failed,
  }) async {
    final json = await request;
    if (json == null) throw StateError(unavailable);
    final data = ApiTransport.unwrap<Map<String, dynamic>>(json);
    if (data == null) {
      throw StateError(json['message']?.toString() ?? failed);
    }
    return data;
  }
}
