import 'dart:convert';
import 'package:baka/api/bangumi_account_api.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/bangumi_sync.dart';
import 'package:baka/services/collection/collection_repository.dart';
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
}
