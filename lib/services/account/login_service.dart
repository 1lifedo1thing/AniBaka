import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/api/api_config.dart';
import 'package:baka/models/app_user.dart';
import 'package:baka/models/token_response.dart';
import 'package:flutter/foundation.dart';

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
      );
      if (res == null) {
        return (success: false, message: '登录失败，请检查网络');
      }
      if (res['code'] != 200) {
        return (
          success: false,
          message: res['msg']?.toString() ?? '登录失败，请检查账号密码',
        );
      }

      await session.login(
        TokenResponse.fromJson(res),
        AppUser.fromJson(res['user'] as Map<String, dynamic>),
      );

      return (success: true, message: '登录成功');
    } catch (e) {
      debugPrint('登录错误: $e');
      return (success: false, message: '登录失败，请检查网络');
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
      );
      if (res == null) {
        return (success: false, message: '注册失败，请检查网络');
      }
      final bool ok = res['code'] == 200;
      final String msg = res['msg']?.toString() ?? (ok ? '注册成功' : '注册失败');

      return (success: ok, message: msg);
    } catch (e) {
      debugPrint('注册错误: $e');
      return (success: false, message: '注册失败，请检查网络');
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
          });
      if (result == null) {
        return (success: false, message: '更新失败，请检查网络', user: null);
      }
      if (result['code'] != 200) {
        return (
          success: false,
          message: result['msg']?.toString() ?? '更新失败',
          user: null,
        );
      }
      final updated = AppUser.fromJson(
        result['data'] as Map<String, dynamic>,
        retainedPasswordMarker: current.passwordMarker ?? '',
      );
      return (success: true, message: '更新成功', user: updated);
    } catch (_) {
      return (success: false, message: '更新失败，请检查网络', user: null);
    }
  }
}
