import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:baka/core/system_proxy.dart';
import 'package:baka/source/webview_adapter.dart';

class SiteProbeRequest {
  const SiteProbeRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
    this.render = false,
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
  final bool render;

  factory SiteProbeRequest.fromJson(Map<String, dynamic> json) {
    return SiteProbeRequest(
      method: (json['method'] as String?)?.toUpperCase() ?? 'GET',
      url: (json['url'] as String?)?.trim() ?? '',
      headers: json['headers'] is Map
          ? {
              for (final entry in (json['headers'] as Map).entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const {},
      body: json['body']?.toString(),
      render: json['render'] == true || json['mode'] == 'webview',
    );
  }
}

class SiteProbeService {
  SiteProbeService() : _client = SystemProxyService.createHttpClient() {
    _client
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 8);
  }

  static const int maxResponseBytes = 48 * 1024;
  static const int maxRequestBodyBytes = 32 * 1024;

  static final RegExp _sensitivePattern = RegExp(
    r'token|auth|sign|key|password|cookie',
    caseSensitive: false,
  );
  static final RegExp _exceptionPrefixPattern = RegExp(r'^\w+(?:Exception)?:\s*');
  static final RegExp _bearerPattern = RegExp(r'Bearer\s+\S+', caseSensitive: false);
  static final RegExp _urlPattern = RegExp(r'https?://[^\s]+');

  static const _sensitiveHeaders = {
    'authorization',
    'cookie',
    'host',
    'content-length',
    'connection',
    'proxy-authorization',
    'x-api-key',
  };

  final HttpClient _client;
  final WebViewTaskScope _webViewScope = WebViewTaskScope();
  final Map<String, List<Cookie>> _cookies = {};
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _webViewScope.cancel();
    _client.close(force: true);
  }

  Future<Map<String, dynamic>> execute(SiteProbeRequest request) async {
    if (_cancelled) throw StateError('AI 规则任务已取消');
    final method = request.method;
    if (method != 'GET' && method != 'HEAD' && method != 'POST') {
      throw FormatException('不允许的探测方法：$method');
    }
    final parsedUri = Uri.tryParse(request.url);
    if (parsedUri == null) throw const FormatException('探测 URL 无效');
    var uri = parsedUri;

    if (request.render) {
      if (method != 'GET') throw const FormatException('WebView 探测只允许 GET');
      await validatePublicUri(uri);
      final (html, _) = await WebViewAdapter.getPageContentWithCookies(
        uri.toString(),
        timeout: const Duration(seconds: 30),
        settleDelay: const Duration(seconds: 2),
        userAgent:
            request.headers['User-Agent'] ?? WebViewAdapter.desktopUserAgent,
        taskScope: _webViewScope,
      );
      _throwIfCancelled();
      final truncated = html.length > maxResponseBytes;
      return {
        'request': {'method': method, 'url': safeUrl(uri), 'render': true},
        'status': html.isEmpty ? 0 : 200,
        'finalUrl': safeUrl(uri),
        'contentType': 'text/html; rendered=webview',
        'headers': <String, String>{},
        'body': truncated ? '${html.substring(0, maxResponseBytes)}…' : html,
        'truncated': truncated,
      };
    }

    for (var redirect = 0; redirect <= 3; redirect++) {
      await validatePublicUri(uri);
      final req = await _client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 10));
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, 'AniBaka-AI-Rule-Probe/1.0');
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      for (final entry in request.headers.entries) {
        if (_sensitiveHeaders.contains(entry.key.toLowerCase())) continue;
        req.headers.set(entry.key, entry.value);
      }
      final cookies = _cookies[uri.host];
      if (cookies != null && cookies.isNotEmpty) req.cookies.addAll(cookies);
      if (method == 'POST' && request.body != null) {
        final bytes = utf8.encode(request.body!);
        if (bytes.length > maxRequestBodyBytes) {
          throw const FormatException('探测请求体过大');
        }
        req.add(bytes);
      }

      final response = await req.close().timeout(const Duration(seconds: 12));
      if (response.cookies.isNotEmpty) {
        _cookies[uri.host] = response.cookies;
      }
      if (response.isRedirect && response.headers.value('location') != null) {
        if (redirect == 3) throw StateError('探测重定向次数过多');
        uri = uri.resolve(response.headers.value('location')!);
        await response.drain<void>();
        continue;
      }

      final builder = BytesBuilder(copy: false);
      var currentLen = 0;
      var truncated = false;
      await for (final chunk in response) {
        if (currentLen + chunk.length <= maxResponseBytes) {
          builder.add(chunk);
          currentLen += chunk.length;
        } else {
          final remaining = maxResponseBytes - currentLen;
          if (remaining > 0) builder.add(chunk.sublist(0, remaining));
          truncated = true;
          break;
        }
      }

      return {
        'request': {'method': method, 'url': safeUrl(uri)},
        'status': response.statusCode,
        'finalUrl': safeUrl(uri),
        'contentType': response.headers.contentType?.toString() ?? '',
        'headers': {
          for (final name in const ['content-type', 'location', 'server'])
            if (response.headers.value(name) != null)
              name: response.headers.value(name),
        },
        'body': utf8.decode(builder.takeBytes(), allowMalformed: true),
        'truncated': truncated,
      };
    }
    throw StateError('探测失败');
  }

  static Future<void> validatePublicUri(Uri uri) async {
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw const FormatException('只允许公开 HTTP(S) 地址');
    }
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost')) {
      throw const FormatException('不允许访问本机地址');
    }
    final addresses = await InternetAddress.lookup(
      host,
    ).timeout(const Duration(seconds: 5));
    if (addresses.isEmpty || addresses.any(_isPrivateAddress)) {
      throw const FormatException('不允许访问私网或保留地址');
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) throw StateError('AI 规则任务已取消');
  }

  static bool _isPrivateAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return _isPrivateIpv4(bytes[0], bytes[1]);
    }
    if (bytes.length == 16) {
      var isMapped = bytes[10] == 0xff && bytes[11] == 0xff;
      if (isMapped) {
        for (var i = 0; i < 10; i++) {
          if (bytes[i] != 0) {
            isMapped = false;
            break;
          }
        }
      }
      if (isMapped) return _isPrivateIpv4(bytes[12], bytes[13]);

      var allZero = true;
      for (var i = 0; i < 16; i++) {
        if (bytes[i] != 0) {
          allZero = false;
          break;
        }
      }
      if (allZero) return true;

      final b0 = bytes[0];
      if (b0 == 0xfc || b0 == 0xfd) return true;
      return b0 == 0xfe && (bytes[1] & 0xc0) == 0x80;
    }
    return false;
  }

  static bool _isPrivateIpv4(int a, int b) =>
      a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      a >= 224;

  static String safeUrl(Uri uri) {
    if (uri.queryParameters.isEmpty) {
      return uri.replace(userInfo: '', fragment: '').toString();
    }
    final query = <String, String>{};
    for (final entry in uri.queryParameters.entries) {
      query[entry.key] =
          _sensitivePattern.hasMatch(entry.key) ? '<redacted>' : entry.value;
    }
    return uri
        .replace(userInfo: '', fragment: '', queryParameters: query)
        .toString();
  }

  static String safeError(Object error, {int maxLength = 500}) {
    var text = error.toString().replaceFirst(_exceptionPrefixPattern, '');
    text = text.replaceAll(_bearerPattern, 'Bearer <redacted>');
    text = text.replaceAllMapped(_urlPattern, (match) {
      final uri = Uri.tryParse(match.group(0)!);
      if (uri == null) return '<url>';
      return safeUrl(uri);
    });
    return text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';
  }
}

