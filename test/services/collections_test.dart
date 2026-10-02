import 'dart:async';
import 'dart:convert';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/models/page.dart';
import 'package:baka/pages/library/library_page.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/bangumi_sync.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CollectionsApi extends BangumiApi {
  @override
  Future<List<AnimeCollection>> getAnimeCollections(
    String token,
    String username,
  ) async => [
    for (var i = 1; i <= 100; i++)
      parseBangumiCollection({
        'subject_id': i,
        'type': 3,
        'subject': {'id': i, 'name': 'Show $i'},
      }),
  ];
}

class _LoadingCollections extends CollectionRepository {
  _LoadingCollections(super.session, super.bangumi);

  final response = Completer<PageData<AnimeCollection>?>();

  @override
  Future<PageData<AnimeCollection>?> getList({
    int page = 1,
    int pageSize = 20,
    int? status,
    int? bgmId,
  }) => response.future;
}

Future<void> _navigateAwayAndBack(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  unawaited(
    navigator.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Next'))),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.takeException(), isNull);
  navigator.pop();
  await tester.pump();
  expect(tester.takeException(), isNull);
  await tester.pump(const Duration(milliseconds: 400));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CollectionRepository repo;
  late BangumiSession bangumi;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final session = AccountSession(prefs, refreshTokens: (_) async => null);
    bangumi = BangumiSession(
      prefs,
      session,
      CollectionsApi(),
      const BangumiOAuthBroker(),
    );
    repo = CollectionRepository(session, bangumi);
    addTearDown(bangumi.api.close);
  });

  test(
    'batch replaces matching identities and retains stats and order',
    () async {
      await repo.storeAll([
        AnimeCollection(postId: 1, status: 1),
        AnimeCollection(bgmId: 2, status: 3),
      ]);
      await repo.storeAll([
        AnimeCollection(postId: 1, bgmId: 10, status: 2),
        AnimeCollection(bgmId: 2, status: 2),
        AnimeCollection(bgmId: 3, status: 1),
      ]);
      expect((await repo.getAll()).map((x) => x.bgmId), [10, 2, 3]);
      expect((await repo.getStats())?.collect, 2);
      expect((await repo.getByPostId(1))?.bgmId, 10);
      final stored =
          jsonDecode(prefs.getString('local_anime_collections_v1')!) as List;
      expect(stored.length, 3);
    },
  );

  test(
    'same post with different Bangumi identities is not incorrectly merged',
    () async {
      await repo.storeAll([
        AnimeCollection(postId: 1, bgmId: 2, status: 1),
        AnimeCollection(postId: 1, bgmId: 3, status: 1),
      ]);
      expect((await repo.getAll()).length, 2);
      expect((await repo.getByBgmId(3))?.bgmId, 3);
    },
  );

  test(
    'sync imports the complete batch and publishes snapshots after storage',
    () async {
      await prefs.setString('bangumi_access_token', 'token');
      await prefs.setString(
        'bangumi_account',
        '{"username":"test","nickname":"Test"}',
      );
      final sync = BangumiSyncService(bangumi, repo);
      final first = sync.sync();
      expect(identical(first, sync.sync()), isTrue);
      expect((await first).imported, 100);
      expect((await repo.getAll(refreshBangumi: false)).length, 100);
      expect(
        (jsonDecode(prefs.getString('bangumi_local_sync_snapshot')!) as Map)
            .length,
        100,
      );
    },
  );
  test('local indexes and cached stats follow mutations', () async {
    await prefs.setString(
      'local_anime_collections_v1',
      jsonEncode([
        {'post_id': 11, 'bgm_id': 101, 'status': 1},
        {'post_id': 12, 'bgm_id': 102, 'status': 3},
      ]),
    );
    expect((await repo.getByBgmId(101))?.postId, 11);
    expect((await repo.getByPostId(12))?.bgmId, 102);
    var stats = await repo.getStats();
    expect(stats?.wish, 1);
    expect(stats?.doing, 1);

    await repo.addOrUpdate(AnimeCollection(postId: 11, bgmId: 101, status: 2));
    stats = await repo.getStats();
    expect(stats?.wish, 0);
    expect(stats?.collect, 1);
    expect((await repo.getByPostId(11))?.status, 2);

    expect(await repo.deleteByBgmId(102), isTrue);
    expect(await repo.getByBgmId(102), isNull);
    expect((await repo.getStats())?.total, 1);
  });

  group('library navigation', () {
    setUp(() {
      Instances.sp = prefs;
      collections = repo;
      historyRepository = HistoryRepository(repo.session, bangumi);
    });

    testWidgets('collections with shared or missing ids allow push and pop', (
      tester,
    ) async {
      await prefs.setString(
        'local_anime_collections_v1',
        jsonEncode([
          {'post_id': 0, 'bgm_id': 101, 'status': 3},
          {'post_id': 0, 'bgm_id': 102, 'status': 3},
          {'post_id': 7, 'bgm_id': 103, 'status': 3},
          {'post_id': 7, 'bgm_id': 104, 'status': 3},
          {'bgm_id': 7, 'status': 3},
          {'status': 3},
        ]),
      );
      await tester.pumpWidget(
        const MaterialApp(home: LibraryPage(initialIndex: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Hero), findsNWidgets(6));
      final tags = tester
          .widgetList<Hero>(find.byType(Hero))
          .map((h) => h.tag)
          .toList();

      await _navigateAwayAndBack(tester);
      expect(
        tester.widgetList<Hero>(find.byType(Hero)).map((h) => h.tag),
        tags,
      );
    });

    testWidgets('loading placeholders allow push and pop before data arrives', (
      tester,
    ) async {
      final loading = _LoadingCollections(repo.session, bangumi);
      collections = loading;
      await tester.pumpWidget(
        const MaterialApp(home: LibraryPage(initialIndex: 1)),
      );
      expect(find.byType(Hero).evaluate().length, greaterThan(1));

      await _navigateAwayAndBack(tester);
      loading.response.complete((
        list: <AnimeCollection>[],
        total: 0,
        page: 1,
        pageSize: 20,
      ));
      await tester.pumpAndSettle();
      expect(find.text('暂无追番记录'), findsOneWidget);
    });

    testWidgets('coexisting library pages have independent cover heroes', (
      tester,
    ) async {
      await repo.storeAll([AnimeCollection(postId: 1, status: 3)]);
      await tester.pumpWidget(
        const MaterialApp(
          home: IndexedStack(
            children: [
              LibraryPage(initialIndex: 1),
              LibraryPage(initialIndex: 1),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Hero, skipOffstage: false), findsNWidgets(2));

      await _navigateAwayAndBack(tester);
    });
  });
}
