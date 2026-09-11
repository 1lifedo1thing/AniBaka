import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:baka/instance.dart';
import 'package:baka/app/navigation.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:baka/widgets/watch_party/watch_party_sheet.dart';
import 'package:flutter/material.dart';
import 'package:win32_registry/win32_registry.dart';

import 'package:baka/services/playback/watch_party.dart';

class WatchPartyLinks {
  WatchPartyLinks(this.party, {this.incoming});
  final Stream<Uri>? incoming;
  // --- 深度链接与协议关联处理 ---

  final AppLinks _links = AppLinks();
  final WatchPartyService party;
  final _ready = Completer<void>();
  bool _closed = false;

  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> close() async {
    _closed = true;
    markReady();
    await _linkSubscription?.cancel();
    _linkSubscription = null;
  }

  StreamSubscription<Uri>? _linkSubscription;
  bool _handlingLink = false;

  /// 初始化 AppLinks 监听和 Windows 协议注册
  void initializeLinks() {
    if (_linkSubscription != null) return;
    _linkSubscription = (incoming ?? _links.uriLinkStream).listen(
      _handleLinkUri,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.instance.warning(
          'Unable to process app link',
          tag: 'WatchParty',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  Future<void> _handleLinkUri(Uri uri) async {
    final code = _inviteCodeFromUri(uri);
    if (code != null) await joinInviteLink(code);
  }

  /// 从字符串解析邀请码（支持 URL、URI 或纯邀请码）
  static String? inviteCodeFromValue(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    final uri = Uri.tryParse(normalized);
    final fromUri = uri == null ? null : _inviteCodeFromUri(uri);
    if (fromUri != null) return fromUri;
    return RegExp(r'^[A-Za-z0-9_-]{6,128}$').hasMatch(normalized)
        ? normalized
        : null;
  }

  /// 通过邀请码加入房间并自动引导播放器与弹窗
  Future<void> joinInviteLink(String code) async {
    await _ready.future;
    if (_closed) return;
    final normalized = code.trim();
    if (normalized.isEmpty || _handlingLink) return;
    _handlingLink = true;
    try {
      await party.joinInvite(normalized);
      await _openMatchingPlayerWhenNeeded();
      _showRoomWhenReady();
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'Unable to join watch party',
        tag: 'WatchParty',
        error: error,
        stackTrace: stackTrace,
      );
      _showErrorWhenReady(error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      _handlingLink = false;
    }
  }

  static String? _inviteCodeFromUri(Uri uri) {
    if (uri.scheme == 'anibaka' &&
        uri.host.toLowerCase() == 'watch' &&
        uri.pathSegments.isNotEmpty) {
      return _validInviteCode(uri.pathSegments.first);
    }
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        (uri.host.toLowerCase() == 'www.anibaka.com' ||
            uri.host.toLowerCase() == 'anibaka.com') &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments.first == 'watch') {
      return _validInviteCode(uri.pathSegments[1]);
    }
    return null;
  }

  static String? _validInviteCode(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{6,128}$').hasMatch(value) ? value : null;

  Future<void> _openMatchingPlayerWhenNeeded() async {
    final service = party;
    final media = service.state.value.snapshot?.media;
    if (media == null ||
        media.bgmSubjectId == null ||
        service.matchesAttachedMedia(media)) {
      return;
    }
    final context = Instances.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    NavigationService.toPlayer(
      context,
      <String, dynamic>{
        'id': media.bgmSubjectId,
        'bgmId': media.bgmSubjectId,
        'title': media.title,
        'source': 'bgm',
        'currPlayIndex': media.episodeIndex,
      },
      posIndex: media.episodeIndex,
      autoMatch: true,
    );
  }

  void _showRoomWhenReady() {
    final context = Instances.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      WatchPartySheet.show(context, party);
    }
  }

  void _showErrorWhenReady(String message) {
    final context = Instances.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  static void registerWindowsScheme() {
    RegistryKey? root;
    RegistryKey? scheme;
    RegistryKey? command;
    try {
      root = Registry.currentUser;
      scheme = root.createKey(r'Software\Classes\anibaka');
      scheme.createValue(
        const RegistryValue.string('', 'URL:AniBaka Watch Party'),
      );
      scheme.createValue(const RegistryValue.string('URL Protocol', ''));
      command = scheme.createKey(r'shell\open\command');
      command.createValue(
        RegistryValue.string('', '"${Platform.resolvedExecutable}" "%1"'),
      );
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'Unable to register anibaka:// protocol',
        tag: 'WatchParty',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      command?.close();
      scheme?.close();
      root?.close();
    }
  }
}
