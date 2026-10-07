import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/api/api_config.dart';
import 'package:baka/models/app_user.dart';
import 'package:baka/models/token_response.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class LoginService {
  LoginService(this.session, this.client);

  final AccountSession session;
  final ApiTransport client;

  /// 执行登录流程
  Future<({bool success, String message})> performLogin({
    required String name,
    required String pwd,
  }) async {
    try {
      final res = await client.postJson<Map<String, dynamic>>(
        '${ApiConfig.host}/user/login',
        {'name': name.trim(), 'pwd': pwd, 'platform': 'app'},
        notifyOnError: false,
      );
      if (res['code'] != 200) {
        return (
          success: false,
          message: _responseMessage(res) ?? '登录失败，请检查账号密码',
        );
      }

      await session.login(
        TokenResponse.fromJson(res),
        AppUser.fromJson(res['user'] as Map<String, dynamic>),
      );

      return (success: true, message: '登录成功');
    } catch (e) {
      debugPrint('登录错误: $e');
      return (success: false, message: _failureMessage(e, '登录'));
    }
  }

  /// 执行注册流程
  Future<({bool success, String message})> performRegister({
    required String name,
    required String pwd,
    required String qq,
  }) async {
    try {
      final res = await client.postJson<Map<String, dynamic>>(
        '${ApiConfig.host}/user/register',
        {'name': name.trim(), 'pwd': pwd, 'qq': qq.trim()},
        notifyOnError: false,
      );
      final bool ok = res['code'] == 200;
      final String msg = _responseMessage(res) ?? (ok ? '注册成功' : '注册失败');

      return (success: ok, message: msg);
    } catch (e) {
      debugPrint('注册错误: $e');
      return (success: false, message: _failureMessage(e, '注册'));
    }
  }

  Future<({bool success, String message, AppUser? user})> updateUser(
    AppUser current,
    String field,
    String value,
  ) async {
    try {
      final result = await client
          .postJson<Map<String, dynamic>>('${ApiConfig.host}/user/register', {
            'id': current.id,
            'name': field == 'name' ? value : current.name,
            'qq': field == 'qq' ? value : current.qq,
            'sign': field == 'sign' ? value : current.sign,
            'level': current.level,
            'pwd': field == 'pwd' ? value : '',
          }, notifyOnError: false);
      if (result['code'] != 200) {
        return (
          success: false,
          message: _responseMessage(result) ?? '更新失败',
          user: null,
        );
      }
      final updated = AppUser.fromJson(
        result['data'] as Map<String, dynamic>,
        retainedPasswordMarker: current.passwordMarker ?? '',
      );
      return (success: true, message: '更新成功', user: updated);
    } catch (e) {
      return (success: false, message: _failureMessage(e, '更新'), user: null);
    }
  }

  static String? _responseMessage(Map<String, dynamic> response) {
    for (final key in ['msg', 'message']) {
      final message = response[key];
      if (message is String && message.trim().isNotEmpty) return message.trim();
    }
    return null;
  }

  // These forms display their own result. HTTP rejections must retain the
  // server's reason instead of also triggering the global network toast.
  static String _failureMessage(Object error, String action) {
    if (error is ApiException) {
      final body = error.responseBody;
      if (body != null) {
        try {
          final response = jsonDecode(body);
          if (response is Map<String, dynamic>) {
            final message = _responseMessage(response);
            if (message != null) return message;
          }
        } on FormatException {
          // A gateway may return HTML or plain text instead of an API envelope.
        }
      }
      final status = error.statusCode;
      if (status == null) return error.message;
      if (status == 429) return '请求过于频繁，请稍后重试';
      if (status >= 500) return '服务器暂时不可用（HTTP $status），请稍后重试';
      return '$action失败（HTTP $status），请稍后重试';
    }
    if (error is TimeoutException) return '$action请求超时，请稍后重试';
    if (error is SocketException || error is http.ClientException) {
      return '无法连接服务器，请检查网络或切换 APP 线路';
    }
    if (error is HandshakeException) return '无法建立安全连接，请检查网络或切换 APP 线路';
    if (error is FormatException || error is TypeError) {
      return '服务器响应异常，请稍后重试';
    }
    return '$action失败，请稍后重试';
  }
}
