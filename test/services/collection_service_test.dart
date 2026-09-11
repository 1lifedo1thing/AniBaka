import '../support/app_dependencies.dart';
import 'dart:convert';

import 'package:baka/instance.dart';
import 'package:baka/models/collection.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      'local_anime_collections_v1': jsonEncode([
        {'post_id': 11, 'bgm_id': 101, 'status': 1},
        {'post_id': 12, 'bgm_id': 102, 'status': 3},
      ]),
    });
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
  });

  test('local indexes and cached stats follow mutations', () async {
    expect((await collections.getByBgmId(101))?.postId, 11);
    expect((await collections.getByPostId(12))?.bgmId, 102);
    var stats = await collections.getStats();
    expect(stats?.wish, 1);
    expect(stats?.doing, 1);

    await collections.addOrUpdate(
      AnimeCollection(postId: 11, bgmId: 101, status: 2),
    );
    stats = await collections.getStats();
    expect(stats?.wish, 0);
    expect(stats?.collect, 1);
    expect((await collections.getByPostId(11))?.status, 2);

    expect(await collections.deleteByBgmId(102), isTrue);
    expect(await collections.getByBgmId(102), isNull);
    expect((await collections.getStats())?.total, 1);
  });
}
