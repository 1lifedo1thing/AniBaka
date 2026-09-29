import 'package:baka/utils/title_matcher.dart';
import 'package:baka/api/api_config.dart';
import 'package:baka/core/api_transport.dart';

Future<String> getPlayUrl(String url, {Future<void>? abortTrigger}) async {
  final data = await apiTransport.getData<Map<String, dynamic>>(
    Uri.parse(
      '${ApiConfig.host}/play',
    ).replace(queryParameters: {'url': url}).toString(),
    timeout: const Duration(seconds: 15),
    abortTrigger: abortTrigger,
  );
  final resolved = data['url'];
  if (resolved is! String || resolved.isEmpty) {
    throw const FormatException('播放地址响应缺少 url');
  }
  return resolved;
}

Future<List<dynamic>> getDanmu(
  int bgmId,
  int episodeIndex,
  String? title, {
  Future<void>? abortTrigger,
}) async {
  final season = title == null ? null : extractSeason(title);
  final uri = Uri.https('danmu.anibaka.com', '/danmu/list', {
    'gv': '$bgmId',
    'p': '$episodeIndex',
    if (title != null && title.isNotEmpty) 'title': title,
    if (season != null) 'season': '$season',
  });
  final response = await apiTransport.getJson<Object>(
    uri.toString(),
    abortTrigger: abortTrigger,
  );
  return switch (response) {
    List<dynamic>() => response,
    Map<String, dynamic>() => response['data'] as List<dynamic>,
    _ => throw const FormatException('弹幕响应格式错误'),
  };
}
