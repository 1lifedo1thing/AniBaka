import '../support/app_dependencies.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:baka/core/app_storage.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('catalog and subscriptions', () {
    late Directory hiveDirectory;
    late SourceAdapterService service;
    late SourceCatalog catalog;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      configureTestServices();

      hiveDirectory = await Directory.systemTemp.createTemp(
        'baka-source-test-',
      );
      Hive.init(hiveDirectory.path);
      await Hive.openBox<List>(AppStorage.customSourcesBoxName);

      service = sourceRepository;
      await service.init();
      catalog = sourceCatalog;
      await catalog.clearCustomSources();
    });

    tearDownAll(() async {
      await Hive.close();
      await hiveDirectory.delete(recursive: true);
    });

    test('rule hub uses the GitHub mirror by default', () async {
      expect(
        RuleRepositoryService.defaultSubscription,
        RuleRepositoryService.mirrorSubscription,
      );
      expect(
        RuleRepositoryService.resolveRuleUrl(
          RuleRepositoryService.defaultSubscription,
          'rules/example.json',
        ),
        '${RuleRepositoryService.githubMirrorPrefix}'
        'https://raw.githubusercontent.com/AniBakaBaka/AniBakaRule/main/'
        'rules/example.json',
      );

      await Instances.sp.setStringList('rule_hub_subscriptions', const [
        RuleRepositoryService.directSubscription,
      ]);
      expect(ruleRepository.subscriptions, const [
        RuleRepositoryService.mirrorSubscription,
      ]);
      await Instances.sp.remove('rule_hub_subscriptions');
    });

    test('rule hub subscriptions can be added and removed', () async {
      await Instances.sp.remove('rule_hub_subscriptions');
      const custom = 'https://example.test/rules/index.json';

      expect(await ruleRepository.addSubscription(custom), isTrue);
      expect(ruleRepository.subscriptions, contains(custom));
      expect(await ruleRepository.removeSubscription(custom), isTrue);
      expect(ruleRepository.subscriptions, isNot(contains(custom)));
    });

    test('custom adapter cache follows the current rule revision', () async {
      final source = CustomSourceConfig(
        id: 'cache-test',
        name: 'Cache Test',
        baseUrl: 'https://example.com',
        pipeline: const {
          'search': <Map<String, dynamic>>[],
          'detail': <Map<String, dynamic>>[],
          'play': <Map<String, dynamic>>[],
        },
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      expect(await catalog.addCustomSource(source), isTrue);

      final first = service.adapterFor(
        AdapterRegistry.customSourceKey(source.id),
      );
      expect(first, isNotNull);

      final updated = source.copyWith(name: 'Updated Cache Test');
      expect(await catalog.updateCustomSource(updated), isTrue);

      final second = service.adapterFor(
        AdapterRegistry.customSourceKey(source.id),
      );
      expect(second, isNotNull);
      expect(second, isNot(same(first)));
      expect(second!.name, 'Updated Cache Test');

      expect(await catalog.deleteCustomSource(source.id), isTrue);
    });

    test('rule hub matches official entries by their stable key', () async {
      final source = CustomSourceConfig(
        id: 'bulk-match',
        name: 'Bulk Match',
        baseUrl: 'https://bulk.example.com',
        pipeline: const {
          'search': <Map<String, dynamic>>[],
          'detail': <Map<String, dynamic>>[],
          'play': <Map<String, dynamic>>[],
        },
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      expect(await catalog.addCustomSource(source), isTrue);

      const byId = RuleHubItem(
        id: 'bulk-match',
        name: 'By Id',
        file: 'bulk-match.json',
        version: 2,
      );
      const missing = RuleHubItem(
        id: 'missing',
        name: 'Missing',
        file: 'missing.json',
      );

      final result = ruleRepository.inspectItems(const [byId, missing]);

      expect(result[byId]!.source?.id, source.id);
      expect(result[byId]!.status, InstallStatus.updateAvailable);
      expect(result[missing]!.status, InstallStatus.notInstalled);

      expect(await catalog.deleteCustomSource(source.id), isTrue);
    });

    test(
      'rule hub treats a bundled rule as installed and updates it in place',
      () async {
        const current = RuleHubItem(
          id: 'akianime',
          name: 'AkiAnime',
          file: 'akianime.json',
          version: 4,
        );
        const newer = RuleHubItem(
          id: 'akianime',
          name: 'AkiAnime',
          file: 'akianime.json',
          version: 5,
        );

        await Instances.sp.remove('rule_hub_version:akianime');
        final initial = ruleRepository.inspectItems(const [current, newer]);
        expect(initial[current]!.source?.id, 'akianime');
        expect(initial[current]!.status, InstallStatus.upToDate);
        expect(initial[newer]!.status, InstallStatus.updateAvailable);

        final previousAdapter = service.adapterFor('akianime');
        final result = await ruleRepository.install(
          newer,
          indexUrl: 'asset://assets/rules/index.json',
        );

        expect(result, RuleInstallResult.updated);
        expect(sourceCatalog.customSourceById('akianime'), isNull);
        expect(
          sourceCatalog.customSources.where(
            (source) => source.id == 'akianime',
          ),
          isEmpty,
        );
        expect(
          sourceCatalog.builtinSourceById('akianime')?.baseUrl,
          'https://www.moefun.cc/',
        );
        expect(
          sourceCatalog.builtinSourceById('akianime')?.iconUrl,
          'https://www.moefun.cc/template/dsn2/static/img/ico.png',
        );
        final updatedAdapter = service.adapterFor('akianime');
        expect(updatedAdapter, isNot(same(previousAdapter)));
        expect(updatedAdapter?.baseUrl, 'https://www.moefun.cc/');
        expect(
          ruleRepository.inspectItems(const [newer])[newer]!.status,
          InstallStatus.upToDate,
        );

        expect(await catalog.resetBuiltinSource('akianime'), isTrue);
        await Instances.sp.remove('rule_hub_version:akianime');
        await Instances.sp.remove('rule_hub_source_id:akianime');
      },
    );
  });

  group('builtin migration', () {
    late Directory hiveDirectory;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({'rule_hub_version:xifanacg': 3});
      Instances.sp = await SharedPreferences.getInstance();
      configureTestServices();
      hiveDirectory = await Directory.systemTemp.createTemp(
        'baka-builtin-migration-test-',
      );
      Hive.init(hiveDirectory.path);
      await Hive.openBox<List>(AppStorage.customSourcesBoxName);
    });

    tearDownAll(() async {
      await Hive.close();
      await hiveDirectory.delete(recursive: true);
    });

    test(
      'legacy custom entries with built-in ids migrate to overrides',
      () async {
        final timestamp = DateTime.utc(2026).toIso8601String();
        await AppStorage.customSourcesBox.put('custom_sources', [
          {
            'format': 'anx-rule/2',
            'id': 'akianime',
            'name': 'Migrated AkiAnime',
            'baseUrl': 'https://migrated.akianime.example',
            'pipeline': {
              'search': <Map<String, dynamic>>[],
              'detail': <Map<String, dynamic>>[],
              'play': <Map<String, dynamic>>[],
            },
            'enabled': true,
            'createdAt': timestamp,
            'updatedAt': timestamp,
          },
          {
            'format': 'anx-rule/2',
            'id': 'custom-only',
            'name': 'Custom Only',
            'baseUrl': 'https://custom.example',
            'pipeline': {
              'search': <Map<String, dynamic>>[],
              'detail': <Map<String, dynamic>>[],
              'play': <Map<String, dynamic>>[],
            },
            'enabled': true,
            'createdAt': timestamp,
            'updatedAt': timestamp,
          },
        ]);
        await AppStorage.customSourcesBox.put('builtin_source_overrides', [
          {
            'format': 'anx-rule/2',
            'id': 'xifanacg',
            'name': 'Stale Xifanacg',
            'baseUrl': 'https://anime.xifanacg.com',
            'pipeline': {
              'search': <Map<String, dynamic>>[],
              'detail': <Map<String, dynamic>>[],
              'play': <Map<String, dynamic>>[],
            },
            'enabled': true,
            'createdAt': timestamp,
            'updatedAt': timestamp,
          },
        ]);

        final service = sourceRepository;
        await service.init();

        expect(sourceCatalog.customSourceById('akianime'), isNull);
        expect(sourceCatalog.customSourceById('custom-only'), isNotNull);
        expect(
          sourceCatalog.builtinSourceById('akianime')?.baseUrl,
          'https://migrated.akianime.example',
        );
        expect(
          sourceCatalog.builtinSourceById('xifanacg')?.baseUrl,
          'https://next.xifanacg.com',
        );

        final storedCustom =
            AppStorage.customSourcesBox.get('custom_sources') ?? const [];
        final storedOverrides =
            AppStorage.customSourcesBox.get('builtin_source_overrides') ??
            const [];
        expect(
          storedCustom.whereType<Map>().map((source) => source['id']),
          isNot(contains('akianime')),
        );
        expect(
          storedOverrides.whereType<Map>().map((source) => source['id']),
          contains('akianime'),
        );
        expect(
          storedOverrides.whereType<Map>().map((source) => source['id']),
          isNot(contains('xifanacg')),
        );
        expect(Instances.sp.getInt('rule_hub_version:xifanacg'), isNull);
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
        configureTestServices();
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
