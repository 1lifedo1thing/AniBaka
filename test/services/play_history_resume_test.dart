import '../support/app_dependencies.dart';
import 'package:baka/instance.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/playback_progress.dart';
import 'dart:io';

import 'package:baka/core/app_storage.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    hiveDirectory = await Directory.systemTemp.createTemp(
      'baka-play-resume-test-',
    );
    Hive.init(hiveDirectory.path);
    await Hive.openBox<List>(AppStorage.playHistoryBoxName);
    await Hive.openBox<Map>(AppStorage.videoProgressBoxName);
  });

  setUp(() async {
    await AppStorage.playHistoryBox.clear();
    await AppStorage.videoProgressBox.clear();
    configureTestServices();
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  test('remembers the latest episode across playback sources', () async {
    await historyRepository.rememberEpisode(
      request: PlaybackRequest.fromMap({
        'id': 'source-a-series',
        'bgmId': 123,
        'title': 'Test Anime',
        'source': 'custom_a',
      }),
      episodeIndex: 6,
      urlIndex: 2,
    );

    final resume = historyRepository.getResumeSelection(
      PlaybackRequest.fromMap({
        'id': 'source-b-series',
        'bgmId': 123,
        'title': 'Different Source Title',
        'source': 'custom_b',
      }),
    );

    expect(resume?.episodeIndex, 6);
    expect(resume?.lineIndex, 1);
    final stored = AppStorage.playHistoryBox.get('resume')!.single as Map;
    expect(stored.keys, containsAll(['bgmId', 'index', 'url', 'watchTime']));
    expect(stored, isNot(contains('content')));
    expect(stored, isNot(contains('image')));
    expect(stored, isNot(contains('tag')));
  });

  test('uses existing history as a migration fallback', () async {
    await AppStorage.playHistoryBox.put('history', [
      {
        'id': 'legacy-id',
        'title': 'Legacy Anime',
        'index': 4,
        'url': 1,
        'watchTime': 100,
      },
    ]);

    final resume = historyRepository.getResumeSelection(
      PlaybackRequest.fromMap({'id': 'another-id', 'title': 'Legacy Anime'}),
    );

    expect(resume?.episodeIndex, 4);
  });

  test(
    'newer synced history wins over an older local episode selection',
    () async {
      final request = PlaybackRequest.fromMap({'id': 'series', 'bgmId': 123});
      await AppStorage.playHistoryBox.put('resume', [
        {'id': 'series', 'bgmId': 123, 'index': 1, 'url': 1, 'watchTime': 100},
      ]);
      await AppStorage.playHistoryBox.put('history', [
        {'id': 'remote', 'bgmId': 123, 'index': 4, 'url': 1, 'watchTime': 200},
      ]);
      expect(historyRepository.getResumeSelection(request)?.episodeIndex, 4);
      await historyRepository.rememberEpisode(
        request: request,
        episodeIndex: 2,
        urlIndex: 1,
      );
      expect(historyRepository.getResumeSelection(request)?.episodeIndex, 2);
    },
  );

  test(
    'auto matching receives remembered episode before the catalog is loaded',
    () async {
      final request = PlaybackRequest.fromMap({
        'id': 'source-series',
        'bgmId': 123,
        'title': 'Resume Anime',
        'source': 'custom_a',
      });
      await historyRepository.rememberEpisode(
        request: request,
        episodeIndex: 6,
        urlIndex: 2,
      );
      final content = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: PlaybackRequest.fromMap({
          'id': 123,
          'bgmId': 123,
          'source': 'bgm',
        }),
      );
      addTearDown(content.dispose);
      // PlayerPage passes this value straight to the matching controller.
      expect(content.currPlayIndex, 6);
      expect(content.currUrl, 1);
      await content.loadDetail();
      expect(content.currPlayIndex, 6);
      content.adoptPlaybackRequest(request.copyWith(episodeIndex: 6));
      expect(content.currPlayIndex, 6);
      content.syncVideoData([
        for (var i = 0; i < 8; i++)
          PlaybackEpisode(title: 'Episode $i', lines: ['episode-$i']),
      ]);
      expect(content.currPlayIndex, 6);
      expect(content.currentEpisodeId, 'episode-6');

      final explicit = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: request,
        posIndex: 1,
      );
      addTearDown(explicit.dispose);
      expect(explicit.currPlayIndex, 1);
      expect(request.episodeIndex, isNull);
    },
  );

  test(
    'restores only the same episode across matched sources and keeps rewinds',
    () async {
      final request = PlaybackRequest.fromMap({
        'id': 'source-a',
        'bgmId': 123,
        'title': 'Resume Anime',
        'source': 'custom_a',
        'currPlayIndex': 6,
      });
      await historyRepository.saveHistory(
        request: request,
        episodeIndex: 6,
        urlIndex: 1,
        positionMs: 456789,
        durationMs: 1440000,
      );
      final otherSource = PlaybackRequest.fromMap({
        'id': 'source-b',
        'bgmId': 123,
        'source': 'custom_b',
        'currPlayIndex': 6,
      });
      Duration read(PlaybackRequest target) =>
          historyRepository.getResumePosition(
            videoKey: 'source-b_${target.episodeIndex}_1',
            request: target,
          );
      expect(read(otherSource), const Duration(milliseconds: 456789));
      expect(read(otherSource.copyWith(episodeIndex: 5)), Duration.zero);
      expect(
        read(otherSource.copyWith(metadata: {'id': 'unrelated', 'bgmId': 999})),
        Duration.zero,
      );
      await historyRepository.saveHistory(
        request: otherSource,
        episodeIndex: 6,
        urlIndex: 1,
        positionMs: 3000,
        durationMs: 1440000,
      );
      expect(read(otherSource), const Duration(seconds: 3));
      // A newer explicit seek to the beginning wins over an old history entry.
      await historyRepository.saveProgress('source-b_6_1', Duration.zero);
      expect(read(otherSource), Duration.zero);
    },
  );

  test(
    'loading and pending seeks preserve progress for the opened episode',
    () async {
      final request = PlaybackRequest.fromMap({
        'id': 'series',
        'title': 'Test',
        'source': 'custom_a',
        'currPlayIndex': 2,
        'currUrl': 1,
      });
      const oldPosition = Duration(minutes: 8);
      const duration = Duration(minutes: 24);
      await historyRepository.saveProgress('series_2_1', oldPosition);
      final progress = PlaybackProgress(
        history: historyRepository,
        request: request,
        videoKey: 'series_2_1',
        start: oldPosition,
      );
      await progress.save(
        const PlaybackTimelineState(),
        rememberPosition: true,
      );
      await progress.save(
        const PlaybackTimelineState(duration: duration),
        rememberPosition: true,
      );
      await progress.save(
        const PlaybackTimelineState(
          duration: duration,
          position: Duration(seconds: 1),
        ),
        rememberPosition: true,
      );
      expect(HistoryRepository.readProgress('series_2_1'), oldPosition);
      expect(historyRepository.getHistoryList(), isEmpty);

      // Selection can advance while the old media is still being saved.
      request.episodeIndex = 3;
      await progress.save(
        const PlaybackTimelineState(
          duration: duration,
          position: Duration(minutes: 9),
        ),
        rememberPosition: true,
      );
      expect(
        HistoryRepository.readProgress('series_2_1'),
        const Duration(minutes: 9),
      );
      expect(HistoryRepository.readProgress('series_3_1'), Duration.zero);
      expect(historyRepository.getHistoryList().single['index'], 2);

      await progress.save(
        const PlaybackTimelineState(duration: duration),
        rememberPosition: true,
        seeked: true,
      );
      expect(HistoryRepository.readProgress('series_2_1'), Duration.zero);
      expect(historyRepository.getHistoryList().single['position'], 0);
    },
  );

  test(
    'completed and local playback restore without writing disabled progress',
    () async {
      final request = PlaybackRequest.fromMap({
        'source': '_local',
        'localFilePath': 'test.mp4',
      });
      const duration = Duration(minutes: 24);
      final progress = PlaybackProgress(
        history: historyRepository,
        request: request,
        videoKey: 'test.mp4',
        start: Duration.zero,
      );
      await progress.save(
        const PlaybackTimelineState(
          duration: duration,
          position: Duration(minutes: 8),
        ),
        rememberPosition: false,
      );
      expect(AppStorage.videoProgressBox.isEmpty, isTrue);
      expect(historyRepository.getHistoryList(), isEmpty);
      await progress.save(
        const PlaybackTimelineState(duration: duration, position: duration),
        rememberPosition: true,
      );
      expect(
        historyRepository.getResumePosition(
          videoKey: 'test.mp4',
          request: request,
        ),
        Duration.zero,
      );
    },
  );

  test(
    'player restores remembered episode unless an index is explicit',
    () async {
      final identity = {
        'id': 'not-a-post-id',
        'bgmId': 456,
        'title': 'Resume Anime',
        'source': 'internal',
      };
      await historyRepository.rememberEpisode(
        request: PlaybackRequest.fromMap(identity),
        episodeIndex: 2,
        urlIndex: 1,
      );

      final rememberedService = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: PlaybackRequest.fromMap({
          ...identity,
          'videos': 'Episode 1\$a\nEpisode 2\$b\nEpisode 3\$c',
        }),
      );
      await rememberedService.loadDetail();
      expect(rememberedService.currPlayIndex, 2);

      final explicitService = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: PlaybackRequest.fromMap({
          ...identity,
          'videos': 'Episode 1\$a\nEpisode 2\$b\nEpisode 3\$c',
        }),
        posIndex: 1,
      );
      await explicitService.loadDetail();
      expect(explicitService.currPlayIndex, 1);
    },
  );
}
