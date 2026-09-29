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
import 'package:baka/source/runtime/request_scheduler.dart';
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

    test(
      'LRU protects playing and running adapters until their owners release',
      () async {
        CustomSourceConfig config(int index) => CustomSourceConfig(
          id: 'lru-$index',
          name: 'LRU $index',
          baseUrl: 'https://example.test',
          pipeline: const {'search': [], 'detail': [], 'play': []},
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );
        final owner = Object();
        final running = Completer<void>();
        addTearDown(() async {
          if (!running.isCompleted) running.complete();
          service.releasePlayback(owner);
          for (var i = 0; i < 28; i++) {
            await catalog.deleteCustomSource('lru-$i');
          }
        });
        await catalog.addCustomSource(config(0));
        await catalog.addCustomSource(config(1));
        final playing = service.adapterFor(
          AdapterRegistry.customSourceKey('lru-0'),
        )!;
        final busy = service.adapterFor(
          AdapterRegistry.customSourceKey('lru-1'),
        )!;
        service.retainPlayback(owner, playing);
        final work = busy.runOperation(() => running.future);
        for (var i = 2; i < 28; i++) {
          await catalog.addCustomSource(config(i));
          service.adapterFor(AdapterRegistry.customSourceKey('lru-$i'));
        }
        expect(
          service.adapterFor(AdapterRegistry.customSourceKey('lru-0')),
          same(playing),
        );
        expect(
          service.adapterFor(AdapterRegistry.customSourceKey('lru-1')),
          same(busy),
        );
        await catalog.updateCustomSource(config(0).copyWith(name: 'Revised'));
        expect(
          service.adapterFor(AdapterRegistry.customSourceKey('lru-0')),
          isNot(same(playing)),
        );
        await playing.runOperation(() async {});
        service.releasePlayback(owner);
        await expectLater(
          playing.runOperation(() async {}),
          throwsA(isA<RequestCancelledException>()),
        );
        running.complete();
        await work;
      },
    );

    test(
      'typed search hands off a new playback request without changing the result',
      () async {
        final overrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = overrides);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = 'http://127.0.0.1:${server.port}';
        server.listen((request) async {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              request.uri.path == '/search'
                  ? {
                      'list': [
                        {'id': 'one', 'name': 'Fixture'},
                      ],
                    }
                  : {
                      'episodes': [
                        {'id': '$origin/video.mp4', 'name': 'Episode 1'},
                      ],
                    },
            ),
          );
          await request.response.close();
        });
        addTearDown(() async {
          await catalog.deleteCustomSource('typed-result');
          await server.close(force: true);
        });
        await catalog.addCustomSource(
          CustomSourceConfig(
            id: 'typed-result',
            name: 'Typed result',
            baseUrl: origin,
            pipeline: const {
              'directConnection': true,
              'search': [
                {'op': 'fetch', 'url': '/search'},
                {
                  'op': 'jsonSeries',
                  'listPath': 'list',
                  'detailUrlTemplate': '/detail/{id}',
                },
              ],
              'detail': [
                {'op': 'follow'},
                {
                  'op': 'jsonEpisodes',
                  'episodesPath': 'episodes',
                  'episodeNameKey': 'name',
                  'episodeIdTemplate': '{id:raw}',
                  'sourceName': 'Line 1',
                },
              ],
              'play': [],
            },
          ),
        );
        final result = (await service.search(
          AdapterRegistry.customSourceKey('typed-result'),
          'Fixture',
          skipBgmEnhancement: true,
        )).single;
        final series = result.series;
        final request = (await service.buildPlaybackRequest(result))!;
        expect(result.series, same(series));
        expect(result.id, '$origin/detail/one');
        expect(result.internalData, isNull);
        expect(result.title, 'Fixture');
        expect(request.source, result.source);
        expect(request.episodes.single.lines, ['$origin/video.mp4']);
        expect(request.sourceNames, ['Line 1']);
        expect(request.metadata.containsKey('videoList'), isFalse);
        expect(result.toLegacyMap().containsKey('videoList'), isFalse);
      },
    );

    test('rule hub subscriptions normalize legacy entries and persist', () async {
      await Instances.sp.remove('rule_hub_subscriptions');
      await Instances.sp.setStringList('rule_hub_subscriptions', const [
        RuleRepositoryService.directSubscription,
      ]);
      expect(ruleRepository.subscriptions, const [
        RuleRepositoryService.mirrorSubscription,
      ]);

      const custom = 'https://example.test/rules/index.json';

      expect(await ruleRepository.addSubscription(custom), isTrue);
      expect(ruleRepository.subscriptions, contains(custom));
      expect(await ruleRepository.removeSubscription(custom), isTrue);
      expect(ruleRepository.subscriptions, isNot(contains(custom)));
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
          'https://www.akianime.cc/',
        );
        expect(
          sourceCatalog.builtinSourceById('akianime')?.iconUrl,
          'https://www.akianime.cc/template/dsn2/static/img/ico.png',
        );
        final updatedAdapter = service.adapterFor('akianime');
        expect(updatedAdapter, isNot(same(previousAdapter)));
        expect(updatedAdapter?.baseUrl, 'https://www.akianime.cc/');
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
