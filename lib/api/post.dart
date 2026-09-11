import 'package:baka/api/api_config.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/utils/bgm_utils.dart';

String get host => ApiConfig.host;

Future<List<Map<String, dynamic>>> getPost(
  String sort,
  String tag,
  int page,
  int pageSize, {
  String status = 'public',
  Object uid = '',
  Object uv = '',
}) async => BgmUtils.asMapList(
  await apiTransport.getData<List<dynamic>>(
    '$host/posts?status=$status&sort=$sort&tag=$tag&uid=$uid&uv=$uv'
    '&page=$page&pageSize=$pageSize',
  ),
);

Future<Map<String, dynamic>> getPostDetail(int pid) async =>
    await apiTransport.getData<Map<String, dynamic>>('$host/post/$pid') ??
    (throw StateError('无法获取帖子 $pid'));

Future<String> getPlayUrl(String url) =>
    apiTransport.get('$host/play?url=$url');

Future<List<Map<String, dynamic>>> getSearch(String? key) async =>
    BgmUtils.asMapList(
      await apiTransport.getData<List<dynamic>>('$host/search/posts?key=$key'),
    );

Future<List<dynamic>> getComments(
  int? pid,
  int pageSize,
  String? runame, {
  int page = 1,
}) async =>
    await apiTransport.getData<List<dynamic>>(
      '$host/comments?pid=$pid&runame=$runame&page=$page&pageSize=$pageSize',
    ) ??
    const [];

Future<String> getDanmu(int bgmId, int episodeIndex, String? title) {
  final season = title == null ? null : BgmUtils.extractSeason(title);
  final uri = Uri.https('danmu.anibaka.com', '/danmu/list', {
    'gv': '$bgmId',
    'p': '$episodeIndex',
    if (title != null && title.isNotEmpty) 'title': title,
    if (season != null) 'season': '$season',
  });
  return apiTransport.get(uri.toString());
}

Future<bool> addComment(Map<String, Object?> data) async =>
    ApiTransport.accepted(
      await apiTransport.postJson<Map<String, dynamic>>(
        '$host/comment/add',
        data,
      ),
    );

Future<Map<String, dynamic>> checkAppUpdateApi() async =>
    await apiTransport.getJson<Map<String, dynamic>>(
      'https://version.anibaka.com/',
    ) ??
    (throw StateError('无法获取版本信息'));

Future<String> updateCommentUv(Object cid, Object? name) async =>
    (await apiTransport.postJson<Map<String, dynamic>>(
          '$host/comment/uv?cid=$cid&name=$name',
          {},
        ))!['msg']
        as String;
