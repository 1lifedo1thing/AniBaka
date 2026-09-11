import '../support/app_dependencies.dart';
import 'dart:convert';

import 'package:baka/instance.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bounded writes preserve newest entries and remove expired data',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'match_memory_v1': jsonEncode({
          for (var i = 1; i <= 205; i++)
            'bgm:$i': {
              'source': 'test',
              'seriesId': '$i',
              'updatedAtMs': now - 10000 + i,
            },
          'bgm:999': {
            'source': 'test',
            'seriesId': 'expired',
            'updatedAtMs': 0,
          },
        }),
      });
      Instances.sp = await SharedPreferences.getInstance();
      configureTestServices();
      expect(MatchMemoryService.read(title: '', bgmId: 1), isNull);
      expect(MatchMemoryService.read(title: '', bgmId: 999), isNull);
      expect(MatchMemoryService.read(title: '', bgmId: 6)?.seriesId, '6');
      await MatchMemoryService.writeSuccess(
        title: '',
        bgmId: 6,
        source: 'updated',
        seriesId: 'new',
      );
      await MatchMemoryService.writeSuccess(
        title: '',
        bgmId: 206,
        source: 'test',
        seriesId: '206',
      );
      expect(MatchMemoryService.read(title: '', bgmId: 6)?.source, 'updated');
      expect(MatchMemoryService.read(title: '', bgmId: 7), isNull);
      expect(MatchMemoryService.read(title: '', bgmId: 206)?.seriesId, '206');
      expect(
        (jsonDecode(Instances.sp.getString('match_memory_v1')!) as Map).length,
        200,
      );
      await MatchMemoryService.remove(title: '', bgmId: 206);
      expect(MatchMemoryService.read(title: '', bgmId: 206), isNull);
    },
  );
}
