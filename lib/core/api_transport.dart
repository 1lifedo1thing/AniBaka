import 'dart:async';
import 'dart:convert';
import 'package:baka/core/account_session.dart';
import 'package:http/http.dart' as http;

/// Installed by the composition root; stateless API functions share this pool.
late ApiTransport apiTransport;

class ApiTransport {
  ApiTransport({
    required this.session,
    required this.client,
    required this.version,
    this.onError,
  });
  final AccountSession session;
  final http.Client client;
  final String version;
  final void Function(Object error)? onError;

  Future<String> _send(
    String method,
    String url, {
    Object? data,
    Duration? timeout,
    bool notifyOnError = true,
  }) async {
    if (session.closed) return '';
    final revision = session.generation;
    final uri = Uri.parse(url);
    final auth = uri.path == '/user/login' || uri.path == '/user/refresh';
    final upstreamAuth = uri.path.startsWith('/api/v1/bangumi/oauth/');
    final carriesCredentials = !auth && session.token.isNotEmpty;
    try {
      if (carriesCredentials &&
          session.expiresSoon &&
          !await session.refresh()) {
        if (revision == session.generation) await session.logout();
        return '';
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        if (carriesCredentials && revision != session.generation) return '';
        final token = session.token;
        final abort = Completer<void>();
        final request =
            http.AbortableRequest(method, uri, abortTrigger: abort.future)
              ..headers.addAll({
                'baka-user-agent': version,
                'Content-Type': 'application/json',
                if (!auth && token.isNotEmpty) 'token': token,
              });
        if (data != null) request.body = jsonEncode(data);
        final response = client.send(request).then(http.Response.fromStream);
        final result = timeout == null
            ? await response
            : await response.timeout(
                timeout,
                onTimeout: () {
                  abort.complete();
                  throw TimeoutException('$method $uri', timeout);
                },
              );
        if (carriesCredentials && revision != session.generation) return '';
        if (result.statusCode != 401 || auth) return result.body;

        if (upstreamAuth) return '';
        if (token.isEmpty) return '';
        if (attempt == 0 && (token != session.token || await session.refresh())) {
          continue;
        }
        if (revision == session.generation) await session.logout();
        return '';
      }
    } catch (error) {
      if (notifyOnError && revision == session.generation) onError?.call(error);
    }
    return '';
  }

  Future<String> get(
    String url, {
    Duration? timeout,
    bool notifyOnError = true,
  }) => _send('GET', url, timeout: timeout, notifyOnError: notifyOnError);
  Future<String> post(
    String url,
    Object? data, {
    Duration? timeout,
    bool notifyOnError = true,
  }) => _send(
    'POST',
    url,
    data: data,
    timeout: timeout,
    notifyOnError: notifyOnError,
  );
  Future<String> put(String url, Object? data) => _send('PUT', url, data: data);
  Future<String> delete(String url, {Object? data}) =>
      _send('DELETE', url, data: data);
  Future<T?> getJson<T>(
    String url, {
    Duration? timeout,
    bool notifyOnError = true,
  }) => _decode<T>(get(url, timeout: timeout, notifyOnError: notifyOnError));
  Future<T?> postJson<T>(
    String url,
    Object? data, {
    Duration? timeout,
    bool notifyOnError = true,
  }) => _decode<T>(
    post(url, data, timeout: timeout, notifyOnError: notifyOnError),
  );
  Future<T?> putJson<T>(String url, Object? data) => _decode<T>(put(url, data));
  Future<T?> deleteJson<T>(String url, {Object? data}) =>
      _decode<T>(delete(url, data: data));
  static Future<T?> _decode<T>(Future<String> request) async {
    final body = await request;
    return body.isEmpty ? null : jsonDecode(body) as T;
  }

  /// AniBaka 网关响应信封 `{code, message, data}` 的成功码：
  /// `/api/v1/*` 用 `0`，旧版 `/posts`、`/comments` 等用 `200`。
  static const _successCodes = {0, 200};

  /// 解包信封并取出 `data`。空响应、非成功码或缺少 `data` 时返回 null。
  static T? unwrap<T>(Map<String, dynamic>? json) =>
      json != null && _successCodes.contains(json['code'])
      ? json['data'] as T?
      : null;

  /// 信封写操作是否成功（响应本身没有 `data` 时使用）。
  static bool accepted(Map<String, dynamic>? json) =>
      json != null && _successCodes.contains(json['code']);

  Future<T?> getData<T>(String url, {bool notifyOnError = true}) async =>
      unwrap<T>(
        await getJson<Map<String, dynamic>>(url, notifyOnError: notifyOnError),
      );

  /// 原始 JSON 端点（BGM 网关等，没有 `{code, message, data}` 信封）。
  /// 这类端点要么返回数据，要么请求本身已经失败，空响应按失败处理。
  Future<Map<String, dynamic>> getMap(
    String url, {
    bool notifyOnError = true,
  }) async =>
      await getJson<Map<String, dynamic>>(url, notifyOnError: notifyOnError) ??
      (throw StateError('空响应: $url'));

  /// 原始 JSON 数组端点；语义同 [getMap]。
  Future<List<dynamic>> getRawList(
    String url, {
    bool notifyOnError = true,
  }) async =>
      await getJson<List<dynamic>>(url, notifyOnError: notifyOnError) ??
      (throw StateError('空响应: $url'));

  Future<Map<String, dynamic>> postMap(
    String url,
    Object? data, {
    bool notifyOnError = true,
  }) async =>
      await postJson<Map<String, dynamic>>(
        url,
        data,
        notifyOnError: notifyOnError,
      ) ??
      (throw StateError('空响应: $url'));

  Future<T?> postData<T>(
    String url,
    Object? data, {
    bool notifyOnError = true,
  }) async =>
      unwrap<T>(
        await postJson<Map<String, dynamic>>(
          url,
          data,
          notifyOnError: notifyOnError,
        ),
      );

  Future<T?> deleteData<T>(String url, {Object? data}) async =>
      unwrap<T>(await deleteJson<Map<String, dynamic>>(url, data: data));

  void close() => client.close();
}
