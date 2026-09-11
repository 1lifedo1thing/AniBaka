import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/instance.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';

const tronUsdtAddress = 'TB26auGFvm6DWkHm166a3zTtTDJuX7LZpH';
const communityGroupNumber = 'anibakabaka';
const communityGroupUrl = 'https://t.me/bakabakatv';

extension MineProfile on AccountSession {
  bool get isBangumiLogin => bangumiSession.isConnected;

  BangumiAccount? get bangumiAccount => bangumiSession.account;

  bool get hasIdentity => isLoggedIn || isBangumiLogin;

  String get displayName {
    if (isLoggedIn) return user.value.name;
    final account = bangumiAccount;
    if (account != null) {
      return account.nickname.isNotEmpty ? account.nickname : account.username;
    }
    return '游客，你好';
  }

  String get displaySubtitle {
    if (isLoggedIn) {
      final sign = user.value.sign;
      return sign.isEmpty ? '这个人很懒，还没有签名' : sign;
    }
    if (isBangumiLogin) return 'Bangumi 登录 · 播放历史仅保存在本机';
    return '你还未登录哦〒▽〒';
  }

  String get avatarUrl {
    if (isLoggedIn) return getAvatar(avatar: user.value.qq);
    return BgmUtils.bgmImageProxyUrl(
      bangumiAccount?.avatarUrl ?? '',
      width: 240,
    );
  }

  String get currentHost => Instances.sp.getString('host') ?? 'www.anibaka.com';

  void switchHost() {
    Instances.sp.setString(
      'host',
      currentHost == 'www.anibaka.com' ? 'doro.bakaup.com' : 'www.anibaka.com',
    );
  }
}
