import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// HTTP status and AniBaka envelope errors are distinct from network/JSON errors.
class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.responseBody,
  });

  final String message;
  final int? statusCode;
  final int? code;
  final String? responseBody;

  @override
  String toString() => message;
}

const apiRequestTimeout = Duration(seconds: 20);

/// Sends one request, without session handling or retries. Timeout covers the
/// response body too, and aborts the underlying HTTP request.
Future<http.Response> sendHttp(
  http.Client client,
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  Object? data,
  Duration timeout = apiRequestTimeout,
  Future<void>? abortTrigger,
  bool followRedirects = false,
}) async {
  final abort = Completer<void>();
  final request =
      http.AbortableRequest(
          method,
          uri,
          abortTrigger: abortTrigger == null
              ? abort.future
              : Future.any([abort.future, abortTrigger]),
        )
        ..followRedirects = followRedirects
        ..headers.addAll(headers);
  if (data != null) {
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode(data);
  }
  final response = await client
      .send(request)
      .then(http.Response.fromStream)
      .timeout(
        timeout,
        onTimeout: () {
          abort.complete();
          throw TimeoutException('$method ${uri.origin}${uri.path}', timeout);
        },
      );
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw ApiException(
      'HTTP ${response.statusCode}: $method ${uri.origin}${uri.path}',
      statusCode: response.statusCode,
      responseBody: response.body,
    );
  }
  return response;
}

T decodeJson<T>(String body) {
  if (body.trim().isEmpty) throw const FormatException('空 JSON 响应');
  final value = jsonDecode(body);
  if (value is! T) throw FormatException('JSON 响应类型错误，预期 $T');
  return value;
}
