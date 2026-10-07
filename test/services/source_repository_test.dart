import '../support/app_dependencies.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:baka/core/app_storage.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/source/store/bundled_rule_store.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/widgets/source/source_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('source updates', () {
    late Directory storage;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      storage = await Directory.systemTemp.createTemp('baka-source-updates-');
      Hive.init(storage.path);
      await Hive.openBox<List>(AppStorage.customSourcesBoxName);
      configureSourceServices();
      ruleRepository = RuleRepositoryService(sourceRepository, sourceCatalog);
      addTearDown(ruleRepository.dispose);
      await sourceRepository.init();
    });

    tearDown(() async {
      await Hive.close();
      await storage.delete(recursive: true);
    });

    testWidgets(
      'batch update shows actual revisions and retains failed updates on narrow screens',
      (tester) async {
        CachedNetworkImageProvider.defaultCacheManager = _NoNetworkImageCache();
        final pageRepository = (await tester.runAsync(
          () async => _UpdatePageRepository(sourceRepository, sourceCatalog),
        ))!;
        addTearDown(pageRepository.dispose);
        ruleRepository = pageRepository;
        await Instances.sp.setStringList('rule_hub_subscriptions', [
          'asset://assets/rules/index.json',
        ]);
        await tester.runAsync(() => pageRepository.fetchAll());
        final bundled = BundledRuleStore.versionFor('akianime');
        await tester.binding.setSurfaceSize(const Size(320, 760));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(() async {
          await tester.pumpWidget(
            const MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(1.3)),
                child: SourceManagementPage(),
              ),
            ),
          );
          await pageRepository.fetchAll();
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('2 个源有更新'), findsOneWidget);
        expect(find.text('v$bundled → v${bundled + 1}'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text('全部更新'));
          await Future.wait(pageRepository.started.values.map((c) => c.future));
        });
        await tester.pump();
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('builtin-akianime')),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('builtin-7sefun')),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        await tester.runAsync(() async {
          pageRepository.release['akianime']!.complete();
          await pageRepository.completed['akianime']!.future;
        });
        await tester.pump();
        expect(find.text('正在更新源 · 1 / 2'), findsOneWidget);
        expect(find.text('当前 v${bundled + 1}'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('builtin-akianime')),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        await tester.runAsync(() async {
          pageRepository.release['dm84']!.complete();
          await pageRepository.finished.future;
        });
        await tester.pumpAndSettle();
        expect(find.text('1 个源有更新'), findsOneWidget);
        expect(sourceCatalog.installedVersionFor('akianime'), bundled + 1);
        expect(pageRepository.updateCount, 1);
        expect(tester.takeException(), isNull);
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'batch install advances around slow and failed downloads and persists all successes',
      (tester) async {
        CachedNetworkImageProvider.defaultCacheManager = _NoNetworkImageCache();
        final pageRepository = (await tester.runAsync(
          () async => _InstallPageRepository(sourceRepository, sourceCatalog),
        ))!;
        addTearDown(pageRepository.dispose);
        ruleRepository = pageRepository;
        await Instances.sp.setStringList('rule_hub_subscriptions', [
          'asset://assets/rules/index.json',
        ]);
        final local = CustomSourceConfig(
          id: 'local-fixture',
          name: 'Local fixture',
          baseUrl: 'https://local.test',
          enabled: false,
          pipeline: const {'search': [], 'detail': [], 'play': []},
        );
        await tester.runAsync(() => sourceCatalog.addCustomSource(local));
        await tester.binding.setSurfaceSize(const Size(1280, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(() async {
          await tester.pumpWidget(
            const MaterialApp(home: SourceManagementPage()),
          );
          await pageRepository.fetchAll();
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('一键安装'));
          await Future.wait([
            for (var i = 0; i < 4; i++)
              pageRepository.started['batch-$i']!.future,
          ]);
        });
        await tester.pump();
        expect(pageRepository.started['batch-4']!.isCompleted, isFalse);
        expect(pageRepository.started['batch-5']!.isCompleted, isFalse);
        expect(find.byType(SourceGridCard), findsNWidgets(21));
        expect(
          find.descendant(
            of: find.byType(SourceGridCard),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNWidgets(4),
        );
        final localCard = find.byKey(const ValueKey('custom-local-fixture'));
        expect(
          find.descendant(
            of: localCard,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.descendant(
                  of: localCard,
                  matching: find.byType(FilledButton),
                ),
              )
              .onPressed,
          isNull,
        );

        await tester.runAsync(() async {
          pageRepository.release['batch-1']!.complete();
          await pageRepository.started['batch-4']!.future;
          pageRepository.release['batch-2']!.complete();
          await pageRepository.started['batch-5']!.future;
        });
        await tester.pump();
        expect(find.text('正在安装源 · 2 / 6'), findsOneWidget);
        expect(pageRepository.completed['batch-0']!.isCompleted, isFalse);
        final installedCard = find.byKey(const ValueKey('custom-batch-2'));
        expect(installedCard, findsOneWidget);
        expect(
          find.descendant(
            of: installedCard,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        await tester.runAsync(() async {
          for (final id in ['batch-0', 'batch-3', 'batch-4', 'batch-5']) {
            pageRepository.release[id]!.complete();
          }
          await pageRepository.finished.future;
        });
        await tester.pumpAndSettle();
        expect(pageRepository.peakDownloads, 4);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(pageRepository.hubCatalog.installable.single.item.id, 'batch-1');
        await tester.runAsync(() async {
          final restored = SourceCatalog(Instances.sp);
          await restored.init();
          expect(restored.customSources.length, 6);
          expect(restored.customSourceById(local.id)?.enabled, isFalse);
          for (final i in [0, 2, 3, 4, 5]) {
            expect(restored.customSourceById('batch-$i'), isNotNull);
            expect(restored.installedVersionFor('batch-$i'), 1);
          }
          expect(restored.customSourceById('batch-1'), isNull);
          restored.dispose();
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    test(
      'updates notify outside the page, deduplicate, survive failures and clear after install',
      () async {
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousOverrides);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        await Instances.sp.setStringList('rule_hub_subscriptions', [
          '$origin/first/index.json',
          '$origin/second/index.json',
        ]);
        final bundled = BundledRuleStore.versionFor('akianime');
        var indexCalls = 0;
        var offline = false;
        var newer = true;
        final custom = CustomSourceConfig(
          id: 'update-fixture',
          name: 'Custom fixture',
          baseUrl: origin,
          pipeline: const {'search': [], 'detail': [], 'play': []},
        );
        await sourceCatalog.addCustomSource(custom);
        await Instances.sp.setInt(
          SourceCatalog.installedVersionKey(custom.id),
          1,
        );
        await sourceCatalog.setBuiltinEnabled('akianime', false);
        server.listen((request) async {
          if (request.uri.path.endsWith('index.json')) {
            indexCalls++;
            request.response.statusCode = offline ? 503 : 200;
            request.response.write(
              jsonEncode({
                'format': 'anx-rulehub/2',
                'entries': [
                  {
                    'key': 'akianime',
                    'title': 'AkiAnime',
                    'ref': 'akianime.json',
                    'rev': bundled + (newer ? 1 : 0),
                  },
                  {
                    'key': custom.id,
                    'title': custom.name,
                    'ref': 'broken.json',
                    'rev': 2,
                  },
                  {
                    'key': 'not-installed',
                    'title': 'New source',
                    'ref': 'new.json',
                    'rev': 1,
                  },
                ],
              }),
            );
          } else if (request.uri.path.endsWith('akianime.json')) {
            request.response.write(
              await File('assets/rules/akianime.json').readAsString(),
            );
          } else {
            request.response.statusCode = 503;
          }
          await request.response.close();
        });
        final counts = <int>[];
        ruleRepository.addListener(
          () => counts.add(ruleRepository.updateCount),
        );
        await Future.wait(
          List.generate(5, (_) => ruleRepository.checkForUpdates()),
        );
        expect(indexCalls, 2);
        expect(ruleRepository.updateCount, 2);
        expect(counts, contains(2));
        expect(
          ruleRepository.hubCatalog.updates.map((rule) => rule.item.id).toSet(),
          {'akianime', custom.id},
        );
        await ruleRepository.checkForUpdates();
        expect(indexCalls, 2, reason: 'resume checks are throttled');

        final failed = ruleRepository.hubCatalog.updates.firstWhere(
          (rule) => rule.item.id == custom.id,
        );
        expect(
          await ruleRepository.install(failed.item, indexUrl: failed.indexUrl),
          RuleInstallResult.failed,
        );
        expect(sourceCatalog.installedVersionFor(custom.id), 1);
        expect(ruleRepository.updateCount, 2);
        final update = ruleRepository.hubCatalog.updates.firstWhere(
          (rule) => rule.item.id == 'akianime',
        );
        expect(
          await ruleRepository.install(update.item, indexUrl: update.indexUrl),
          RuleInstallResult.updated,
        );
        expect(ruleRepository.updateCount, 1);
        expect(sourceCatalog.isBuiltinEnabled('akianime'), isFalse);
        expect(sourceCatalog.installedVersionFor('akianime'), bundled + 1);
        expect(sourceCatalog.customSourceById('akianime'), isNull);

        await sourceCatalog.resetBuiltinSource('akianime');
        expect(sourceCatalog.installedVersionFor('akianime'), bundled);
        expect(
          Instances.sp.getInt(SourceCatalog.installedVersionKey('akianime')),
          isNull,
        );
        expect(ruleRepository.updateCount, 2);
        await sourceCatalog.deleteCustomSource(custom.id);
        expect(
          Instances.sp.getInt(SourceCatalog.installedVersionKey(custom.id)),
          isNull,
        );
        expect(ruleRepository.updateCount, 1);

        offline = true;
        await ruleRepository.fetchAll(forceRefresh: true);
        expect(ruleRepository.usingCachedIndices, isTrue);
        expect(ruleRepository.updateCount, 1);
        offline = false;
        newer = false;
        await ruleRepository.fetchAll(forceRefresh: true);
        expect(ruleRepository.usingCachedIndices, isFalse);
        expect(ruleRepository.updateCount, 0);
      },
    );

    test(
      'app upgrade replaces older repository rules while retaining newer and local edits',
      () async {
        final bundled = BundledRuleStore.versionFor('akianime');
        final config = CustomSourceConfig(
          id: 'akianime',
          name: 'Override',
          baseUrl: 'https://override.test',
          pipeline: const {'search': [], 'detail': [], 'play': []},
        );
        for (final revision in [bundled - 1, bundled + 1, null]) {
          await AppStorage.customSourcesBox.put('builtin_source_overrides', [
            config.toJson(),
          ]);
          final key = SourceCatalog.installedVersionKey(config.id);
          if (revision == null) {
            await Instances.sp.remove(key);
          } else {
            await Instances.sp.setInt(key, revision);
          }
          final restored = SourceCatalog(Instances.sp);
          await restored.init();
          if (revision == bundled - 1) {
            expect(restored.builtinOverrideById(config.id), isNull);
            expect(restored.installedVersionFor(config.id), bundled);
            expect(Instances.sp.getInt(key), isNull);
          } else {
            expect(
              restored.builtinSourceById(config.id)?.baseUrl,
              config.baseUrl,
            );
            expect(restored.installedVersionFor(config.id), revision ?? 0);
          }
          restored.dispose();
        }
      },
    );
  });

  group('index cache', () {
    test(
      'index requests share parsing, refresh, offline data and removal',
      () async {
        final previousOverrides = HttpOverrides.current;
        addTearDown(() => HttpOverrides.global = previousOverrides);
        HttpOverrides.global = null;
        SharedPreferences.setMockInitialValues({});
        Instances.sp = await SharedPreferences.getInstance();
        configureSourceServices();
        ruleRepository = RuleRepositoryService(sourceRepository, sourceCatalog);
        addTearDown(ruleRepository.dispose);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final url = 'http://127.0.0.1:${server.port}/index.json';
        final service = ruleRepository;
        await service.addSubscription(url);
        var calls = 0;
        var fail = false;
        Completer<void>? gate;
        final received = StreamController<void>.broadcast();
        addTearDown(received.close);
        final body = jsonEncode({
          'format': 'anx-rulehub/2',
          'entries': [
            {'key': 'test', 'title': 'Test', 'ref': 'test.json', 'rev': 1},
          ],
        });
        server.listen((request) async {
          calls++;
          received.add(null);
          await gate?.future;
          request.response.statusCode = fail ? 503 : 200;
          request.response.write(body);
          await request.response.close();
        });
        final indexes = await Future.wait([
          for (var i = 0; i < 20; i++) service.fetchIndex(url),
        ]);
        expect(calls, 1);
        expect(
          indexes.every((value) => identical(value, indexes.first)),
          isTrue,
        );
        await service.fetchIndex(url);
        expect(calls, 1);
        await Future.wait([
          for (var i = 0; i < 20; i++)
            service.fetchIndex(url, forceRefresh: true),
        ]);
        expect(calls, 2);
        fail = true;
        expect(
          (await service.fetchIndex(url, forceRefresh: true)).rules.single.id,
          'test',
        );
        expect(calls, 3);
        fail = false;
        gate = Completer<void>();
        final started = received.stream.first;
        final old = service.fetchIndex(url, forceRefresh: true);
        await started;
        await service.removeSubscription(url);
        gate.complete();
        await old;
        expect(Instances.sp.getString('rule_hub_cache:$url'), isNull);
        await service.fetchIndex(url);
        expect(calls, 5);
      },
    );
  });
}

abstract class _ControlledPageRepository extends RuleRepositoryService {
  _ControlledPageRepository(super.adapters, super.catalog, List<String> ids)
    : started = {for (final id in ids) id: Completer<void>()},
      release = {for (final id in ids) id: Completer<void>()},
      completed = {for (final id in ids) id: Completer<void>()};

  final Map<String, Completer<void>> started;
  final Map<String, Completer<void>> release;
  final Map<String, Completer<void>> completed;
  final finished = Completer<void>();
  int _activeDownloads = 0;
  int peakDownloads = 0;

  Future<CustomSourceConfig> loadConfig(
    RuleHubItem item, {
    required String indexUrl,
    required bool forceRefresh,
  });

  @override
  Future<CustomSourceConfig> resolveConfig(
    RuleHubItem item, {
    required String indexUrl,
    bool forceRefresh = false,
  }) async {
    _activeDownloads++;
    if (_activeDownloads > peakDownloads) peakDownloads = _activeDownloads;
    started[item.id]!.complete();
    try {
      await release[item.id]!.future;
      return await loadConfig(
        item,
        indexUrl: indexUrl,
        forceRefresh: forceRefresh,
      );
    } finally {
      _activeDownloads--;
    }
  }

  @override
  Future<RuleInstallResult> install(
    RuleHubItem item, {
    required String indexUrl,
  }) async {
    final result = await super.install(item, indexUrl: indexUrl);
    completed[item.id]!.complete();
    if (completed.values.every((c) => c.isCompleted)) finished.complete();
    return result;
  }
}

class _UpdatePageRepository extends _ControlledPageRepository {
  _UpdatePageRepository(SourceAdapterService adapters, SourceCatalog catalog)
    : super(adapters, catalog, ['akianime', 'dm84']);

  @override
  Future<RuleHubIndex> fetchIndex(
    String url, {
    bool forceRefresh = false,
  }) async {
    final index = await super.fetchIndex(url, forceRefresh: forceRefresh);
    return RuleHubIndex(
      sourceUrl: url,
      rules: [
        for (final item in index.rules.where(
          (item) => ['akianime', 'dm84'].contains(item.id),
        ))
          RuleHubItem(
            id: item.id,
            name: item.name,
            file: item.id == 'dm84' ? 'missing-fixture.json' : item.file,
            version: item.version + 1,
          ),
      ],
    );
  }

  @override
  Future<CustomSourceConfig> loadConfig(
    RuleHubItem item, {
    required String indexUrl,
    required bool forceRefresh,
  }) async {
    final body = await File('assets/rules/${item.file}').readAsString();
    return CustomSourceConfig.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
    );
  }
}

class _InstallPageRepository extends _ControlledPageRepository {
  _InstallPageRepository(SourceAdapterService adapters, SourceCatalog catalog)
    : super(adapters, catalog, [for (var i = 0; i < 6; i++) 'batch-$i']);

  @override
  Future<RuleHubIndex> fetchIndex(
    String url, {
    bool forceRefresh = false,
  }) async => RuleHubIndex(
    sourceUrl: url,
    rules: [
      for (final id in started.keys)
        RuleHubItem(id: id, name: id, file: '$id.json', version: 1),
    ],
  );

  @override
  Future<CustomSourceConfig> loadConfig(
    RuleHubItem item, {
    required String indexUrl,
    required bool forceRefresh,
  }) async {
    if (item.id == 'batch-1') throw const FormatException('Invalid rule');
    return CustomSourceConfig(
      id: item.id,
      name: item.name,
      baseUrl: 'https://${item.id}.test',
      pipeline: const {'search': [], 'detail': [], 'play': []},
    );
  }
}

class _NoNetworkImageCache extends Fake implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => const Stream.empty();
}
