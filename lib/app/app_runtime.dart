import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'dart:async';
import 'dart:io';
import 'package:baka/api/api_config.dart';
import 'package:baka/api/auth_api.dart';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/app/platform_setup.dart';
import 'package:baka/app/navigation.dart';
import 'package:baka/app/usage_tracker.dart';
import 'package:baka/app/watch_party_links.dart';
import 'package:baka/app_state.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/core/app_storage.dart';
import 'package:baka/core/system_proxy.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/player/download_page.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/bangumi_sync.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/download/download_manager.dart';
import 'package:baka/services/playback/media_session.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/services/playback/dlss_global_playback.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide ContextExtensionss;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/io_client.dart';

/// Composition root and owner of application-lifetime resources.
class AppRuntime {
  AppRuntime({Future<void> Function()? platformSetup, this.incomingLinks})
    : platformSetup = platformSetup ?? configurePlatform;
  final Future<void> Function() platformSetup;
  final Stream<Uri>? incomingLinks;
  final _cleanup = <FutureOr<void> Function()>[];
  bool _ready = false;
  String? _notifiedSourceUpdates;
  Future<void>? _initializing, _closing;
  Set<PlaybackController>? _playbacks;
  Set<PlaybackController> get playbacks =>
      _playbacks ??= <PlaybackController>{};
  late AccountSession account;
  late WatchPartyService party;
  late WatchPartyLinks links;
  final mediaSession = MediaSessionService();

  Future<void> initialize() => _initializing ??= _initialize().catchError((
    Object error,
    StackTrace stack,
  ) async {
    await _releaseResources();
    _initializing = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _initialize() async {
    WidgetsFlutterBinding.ensureInitialized();
    SystemProxyService.initialize();
    await Instances.init();
    PlaybackSettingsService.applyLowMemoryMode(
      PlaybackSettingsService.getLowMemoryMode(),
    );
    await AppLogger.instance.init();
    final client = IOClient(SystemProxyService.createHttpClient());
    _cleanup.add(client.close);
    final auth = AuthApi(client, () => ApiConfig.host);
    account = AccountSession(Instances.sp, refreshTokens: auth.refresh);
    apiTransport = ApiTransport(
      session: account,
      client: client,
      version: Instances.appVersion,
      credentialOrigin: () => Uri.parse(ApiConfig.host),
      onError: (_) {
        if (_ready) showSnackBar('网络连接失败，请检查网络和线路＞︿＜', isError: true);
      },
    );
    bangumiSession = BangumiSession(
      Instances.sp,
      account,
      BangumiApi(),
      const BangumiOAuthBroker(),
    );
    historyRepository = HistoryRepository(account, bangumiSession);
    collections = CollectionRepository(account, bangumiSession);
    bangumiSync = BangumiSyncService(bangumiSession, collections);
    sourceCatalog = SourceCatalog(Instances.sp);
    sourceRepository = SourceAdapterService(sourceCatalog);
    ruleRepository = RuleRepositoryService(sourceRepository, sourceCatalog);
    downloads = DownloadService();
    party = WatchPartyService(session: account);
    links = WatchPartyLinks(party, incoming: incomingLinks)..initializeLinks();
    _cleanup.addAll([
      account.close,
      bangumiSession.api.close,
      bangumiSession.cancelOAuthLogin,
      sourceCatalog.dispose,
      ruleRepository.dispose,
      sourceRepository.dispose,
      mediaSession.close,
      party.dispose,
      downloads.dispose,
      DanmakuController.clearCache,
      links.close,
    ]);

    Directory? directory;
    if (Instances.isDesktopPlatform) {
      await Instances.prepareDesktopWorkspace(
        legacyHiveBoxes: const [
          AppStorage.videoProgressBoxName,
          AppStorage.customSourcesBoxName,
          AppStorage.downloadTasksBoxName,
          AppStorage.playHistoryBoxName,
          AppStorage.threadCommentsBoxName,
          AppStorage.bgmCacheBoxName,
          AppStorage.homeCacheBoxName,
          'storage_configs',
        ],
      );
      directory = await Instances.desktopDataDirectory('hive');
      Hive.init(directory.path);
    } else {
      await Hive.initFlutter();
    }
    await AppStorage.init(
      hiveDirectory: directory,
      boxes: AppStorage.startupBoxes,
    );
    await platformSetup();
    await DlssGlobalPlayback.instance.initialize();
    _cleanup.add(DlssGlobalPlayback.instance.close);
    Get.put(this, permanent: true);
    Get.put(account, permanent: true);
    Get.put(apiTransport, permanent: true);
    Get.put(AppState(), permanent: true);
    Get.put(party, permanent: true);
    Get.put(links, permanent: true);
    Get.put(mediaSession, permanent: true);
    downloads.onCompleted = (task) => showSnackBar(
      '已缓存 ${task.title}',
      action: SnackBarAction(
        label: '前往缓存中心',
        onPressed: () {
          final context = Instances.navigatorKey.currentContext;
          if (context != null) {
            Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (_, _, _) => const DownloadManagerPage(),
              ),
            );
          }
        },
      ),
    );
  }

  void markReady() {
    if (_closing != null) return;
    _ready = true;
    links.markReady();
    unawaited(DauTracker.track());
    unawaited(checkSourceUpdates());
  }

  Future<void> checkSourceUpdates() async {
    if (!_ready || _closing != null) return;
    await ruleRepository.checkForUpdates();
    if (!_ready || _closing != null || ruleRepository.updateCount == 0) return;
    final versions =
        ruleRepository.hubCatalog.updates
            .map((rule) => '${rule.item.id}:${rule.item.version}')
            .toList()
          ..sort();
    final signature = versions.join(',');
    if (_notifiedSourceUpdates == signature) return;
    _notifiedSourceUpdates = signature;
    showSnackBar(
      '${ruleRepository.updateCount} 个源有更新，可修复搜索或播放问题',
      action: SnackBarAction(
        label: '查看更新',
        onPressed: () {
          final context = Instances.navigatorKey.currentContext;
          if (context != null) NavigationService.toSourceManagement(context);
        },
      ),
    );
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _releaseResources() async {
    for (final release in _cleanup.reversed) {
      try {
        await release();
      } catch (error, stack) {
        AppLogger.instance.warning(
          'Resource shutdown failed',
          tag: 'Lifecycle',
          error: error,
          stackTrace: stack,
        );
      }
    }
    _cleanup.clear();
  }

  Future<void> _close() async {
    _ready = false;
    await links.close();
    for (final playback in playbacks.toList()) {
      try {
        await playback.dispose();
      } catch (error, stack) {
        AppLogger.instance.warning(
          'Playback shutdown failed',
          tag: 'Lifecycle',
          error: error,
          stackTrace: stack,
        );
      }
    }
    playbacks.clear();
    await _releaseResources();
    if (PlaybackSettingsService.getClearCacheOnExit()) {
      await AppStorage.clearAllCache();
    }
    await Hive.close();
  }
}
