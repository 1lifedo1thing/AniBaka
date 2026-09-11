import 'dart:convert';
import 'dart:io';

import 'package:baka/api/api_config.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/system_proxy.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const _bangumiApiBase = 'https://api.bgm.tv';

class BangumiSyncException implements Exception {
  const BangumiSyncException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class BangumiAccount {
  const BangumiAccount({
    required this.username,
    required this.nickname,
    this.avatarUrl,
  });

  final String username;
  final String nickname;
  final String? avatarUrl;

  factory BangumiAccount.fromJson(Map<String, dynamic> json) {
    final avatar = json['avatar'];
    String? avatarUrl;
    if (avatar is Map) {
      avatarUrl = avatar['large']?.toString();
    } else {
      avatarUrl = json['avatar_url']?.toString();
    }
    return BangumiAccount(
      username: json['username']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
      avatarUrl: avatarUrl,
    );
  }

  Map<String, dynamic> toJson() => {
    'username': username,
    'nickname': nickname,
    if (avatarUrl != null) 'avatar_url': avatarUrl,
  };
}

class BangumiOAuthStart {
  const BangumiOAuthStart({
    required this.authorizationUrl,
    required this.state,
  });

  final String authorizationUrl;
  final String state;
}

class BangumiOAuthToken {
  const BangumiOAuthToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
}

class BangumiOAuthBroker {
  const BangumiOAuthBroker();

  Future<BangumiOAuthStart> begin() async {
    final data = await _post('/api/v1/bangumi/oauth/start', const {});
    final authorizationUrl = data['authorization_url']?.toString() ?? '';
    final state = data['state']?.toString() ?? '';
    if (authorizationUrl.isEmpty || state.isEmpty) {
      throw const BangumiSyncException('AniBaka 未返回有效的 Bangumi 登录地址');
    }
    return BangumiOAuthStart(authorizationUrl: authorizationUrl, state: state);
  }

  Future<BangumiOAuthToken> waitForCompletion(String state) async {
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(deadline)) {
      final uri = Uri.parse(
        '${ApiConfig.host}/api/v1/bangumi/oauth/status',
      ).replace(queryParameters: {'state': state});
      final response = await apiTransport.get(
        uri.toString(),
        timeout: const Duration(seconds: 20),
        notifyOnError: false,
      );
      final data = _parseBrokerResponse(response);
      if (data?['status'] == 'complete') return _tokenFromJson(data!);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw const BangumiSyncException('Bangumi 登录超时，请重试');
  }

  Future<BangumiOAuthToken> refresh(String refreshToken) async {
    final data = await _post('/api/v1/bangumi/oauth/refresh', {
      'refresh_token': refreshToken,
    });
    return _tokenFromJson(data);
  }

  static Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await apiTransport.post('${ApiConfig.host}$path', body);
    final data = _parseBrokerResponse(response);
    if (data == null) {
      throw const BangumiSyncException('AniBaka账号未登录');
    }
    return data;
  }

  static Map<String, dynamic>? _parseBrokerResponse(String response) {
    final root = BgmUtils.parseJsonMap(response);
    if (root == null) return null;
    if (BgmUtils.toInt(root['code']) != 0) {
      final msg = root['message']?.toString() ?? 'Bangumi 登录失败';
      if (msg.contains('未配置')) {
        throw const BangumiSyncException(
          '服务端未配置 Bangumi 授权应用，请使用 Access Token 方式连接',
        );
      }
      throw BangumiSyncException(msg);
    }
    return BgmUtils.asMap(root['data']);
  }

  static BangumiOAuthToken _tokenFromJson(Map<String, dynamic> json) {
    final accessToken = json['access_token']?.toString() ?? '';
    if (accessToken.isEmpty) {
      throw const BangumiSyncException('Bangumi 登录未返回有效令牌');
    }
    return BangumiOAuthToken(
      accessToken: accessToken,
      refreshToken: json['refresh_token']?.toString() ?? '',
      expiresIn: BgmUtils.toInt(json['expires_in']) ?? 604800,
    );
  }
}

AnimeCollection parseBangumiCollection(Map<String, dynamic> json) {
  final subject = BgmUtils.asMap(json['subject']);
  final nameCn = subject?['name_cn']?.toString().trim() ?? '';
  final name = subject?['name']?.toString().trim() ?? '';
  final rawTags = json['tags'];
  final tags = rawTags is List
      ? rawTags.map((e) => e.toString()).toList()
      : const <String>[];
  return AnimeCollection(
    bgmId: BgmUtils.toInt(json['subject_id']) ?? 0,
    status: BgmUtils.toInt(json['type']) ?? CollectionStatus.wish.value,
    rating: BgmUtils.toInt(json['rate']) ?? 0,
    epWatched: BgmUtils.toInt(json['ep_status']) ?? 0,
    tags: tags.isEmpty ? null : tags.join(','),
    bangumiTags: tags,
    bgmImage: BgmUtils.bgmCoverProxyUrl(
      BgmUtils.toInt(json['subject_id']) ?? 0,
    ),
    isPrivate: json['private'] == true,
    bgmTitle: nameCn.isNotEmpty ? nameCn : name,
    comment: json['comment']?.toString().trim().isNotEmpty == true
        ? json['comment'].toString().trim()
        : null,
    epTotal: BgmUtils.toInt(subject?['eps']),
    bgmRating: BgmUtils.toDouble(subject?['score']),
  );
}

class _BangumiEpisodeRecord {
  const _BangumiEpisodeRecord({
    required this.id,
    required this.collectionType,
    required this.sort,
  });

  final int id;
  final int collectionType;
  final double sort;

  factory _BangumiEpisodeRecord.fromJson(Map<String, dynamic> json) {
    final episode = BgmUtils.asMap(json['episode']);
    return _BangumiEpisodeRecord(
      id: BgmUtils.toInt(episode?['id']) ?? 0,
      collectionType: BgmUtils.toInt(json['type']) ?? 0,
      sort: BgmUtils.toDouble(episode?['sort']) ?? 0,
    );
  }
}

class BangumiApi {
  BangumiApi() : _client = IOClient(SystemProxyService.createHttpClient());

  final http.Client _client;
  void close() => _client.close();

  Future<BangumiAccount> getMe(String token) async {
    final json = await _request('GET', '/v0/me', token: token);
    return BangumiAccount.fromJson(BgmUtils.parseJsonMap(json) ?? const {});
  }

  Future<AnimeCollection?> getCollection(String token, int subjectId) async {
    try {
      final json = await _request(
        'GET',
        '/v0/users/-/collections/$subjectId',
        token: token,
      );
      final map = BgmUtils.parseJsonMap(json);
      return map == null ? null : parseBangumiCollection(map);
    } on BangumiSyncException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) async {
    const limit = 100;
    var offset = 0;
    var total = 1;
    final result = <AnimeCollection>[];

    while (offset < total) {
      final path = Uri(
        path: '/v0/users/$username/collections',
        queryParameters: {
          'subject_type': '2',
          'limit': '$limit',
          'offset': '$offset',
        },
      ).toString();
      final page =
          BgmUtils.parseJsonMap(await _request('GET', path, token: token)) ??
          const <String, dynamic>{};
      total = BgmUtils.toInt(page['total']) ?? 0;
      final items = BgmUtils.parseJsonList(page['data']);
      for (final item in items) {
        final map = BgmUtils.asMap(item);
        if (map == null) continue;
        final record = parseBangumiCollection(map);
        if ((record.bgmId ?? 0) > 0) result.add(record);
      }
      if (items.isEmpty) break;
      offset += items.length;
    }
    return result;
  }

  Future<void> putCollection(String token, AnimeCollection collection) async {
    final subjectId = collection.bgmId;
    if (subjectId == null || subjectId <= 0) return;
    await _request(
      'POST',
      '/v0/users/-/collections/$subjectId',
      token: token,
      body: {
        'type': collection.status,
        'rate': collection.rating,
        'comment': collection.comment ?? '',
        'private': collection.isPrivate,
        'tags': parseCollectionTags(collection.tags),
      },
    );
  }

  Future<void> putEpisodeProgress(
    String token,
    int subjectId,
    int watched,
  ) async {
    final path = Uri(
      path: '/v0/users/-/collections/$subjectId/episodes',
      queryParameters: const {'episode_type': '0', 'limit': '1000'},
    ).toString();
    final page =
        BgmUtils.parseJsonMap(await _request('GET', path, token: token)) ??
        const <String, dynamic>{};
    final episodes = <_BangumiEpisodeRecord>[];
    for (final item in BgmUtils.parseJsonList(page['data'])) {
      final map = BgmUtils.asMap(item);
      if (map == null) continue;
      final episode = _BangumiEpisodeRecord.fromJson(map);
      if (episode.id > 0) episodes.add(episode);
    }
    episodes.sort((a, b) => a.sort.compareTo(b.sort));

    final watchedCount = watched.clamp(0, episodes.length);
    final doneIds = <int>[];
    final resetIds = <int>[];
    for (var index = 0; index < episodes.length; index++) {
      final episode = episodes[index];
      if (index < watchedCount) {
        if (episode.collectionType != 2) doneIds.add(episode.id);
      } else if (episode.collectionType == 2) {
        resetIds.add(episode.id);
      }
    }
    if (doneIds.isNotEmpty) {
      await _putEpisodes(token, subjectId, doneIds, 2);
    }
    if (resetIds.isNotEmpty) {
      await _putEpisodes(token, subjectId, resetIds, 0);
    }
  }

  Future<void> _putEpisodes(
    String token,
    int subjectId,
    List<int> episodeIds,
    int type,
  ) {
    return _request(
      'PATCH',
      '/v0/users/-/collections/$subjectId/episodes',
      token: token,
      body: {'episode_id': episodeIds, 'type': type},
    ).then((_) {});
  }

  Future<dynamic> _request(
    String method,
    String path, {
    required String token,
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, Uri.parse('$_bangumiApiBase$path'));
    request.headers.addAll({
      HttpHeaders.authorizationHeader: 'Bearer $token',
      HttpHeaders.acceptHeader: 'application/json',
      HttpHeaders.userAgentHeader:
          'AniBakaBaka/AniBaka/${Instances.appVersion} '
          '(${Platform.operatingSystem}) '
          '(https://github.com/AniBakaBaka/AniBaka)',
      if (body != null) HttpHeaders.contentTypeHeader: 'application/json',
    });
    if (body != null) request.body = jsonEncode(body);

    http.StreamedResponse streamed;
    try {
      streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
    } on BangumiSyncException {
      rethrow;
    } catch (_) {
      throw const BangumiSyncException('无法连接 Bangumi；部分网络环境可能需要先开启代理软件');
    }
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const BangumiSyncException('Bangumi Access Token 无效、已过期或权限不足');
      }
      var message = 'Bangumi 请求失败（${response.statusCode}）';
      try {
        final error = BgmUtils.parseJsonMap(response.body) ?? const {};
        final detail = error['description'] ?? error['title'];
        if (detail != null && detail.toString().isNotEmpty) {
          message = detail.toString();
        }
      } catch (_) {}
      throw BangumiSyncException(message, statusCode: response.statusCode);
    }
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw const BangumiSyncException('Bangumi 返回了无法识别的数据');
    }
  }
}

String localCollectionFingerprint(AnimeCollection collection) =>
    collectionFingerprint(
      status: collection.status,
      rating: collection.rating,
      comment: collection.comment,
      episodeWatched: collection.epWatched ?? 0,
      tags: collection.bangumiTags ?? parseCollectionTags(collection.tags),
      isPrivate: collection.isPrivate,
    );

String collectionFingerprint({
  required int status,
  required int rating,
  required String? comment,
  required int episodeWatched,
  required List<String> tags,
  required bool isPrivate,
}) {
  final tagStr = tags.isEmpty
      ? ''
      : (tags.length == 1
            ? tags.first
            : (List<String>.from(tags)..sort()).join(','));
  return '$status|$rating|${comment?.trim() ?? ''}|$episodeWatched|$tagStr|${isPrivate ? 1 : 0}';
}

List<String> parseCollectionTags(String? value) {
  if (value == null || value.trim().isEmpty) return const [];
  return value
      .split(RegExp(r'[,，\s]+'))
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toSet()
      .toList();
}
