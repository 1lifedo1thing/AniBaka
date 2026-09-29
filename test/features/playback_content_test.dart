import '../support/app_dependencies.dart';
import 'dart:io';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _KeepAliveAdapter extends AdapterBase {
  _KeepAliveAdapter() : super('keep-alive-test');

  int starts = 0;
  int stops = 0;
  String? lastMediaUrl;

  @override
  String get baseUrl => 'https://example.com';

  @override
  Future<String> getDownloadUrl(String episodeId) async => '';

  @override
  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
  }) async => (
    url: episodeId == 'good' ? 'https://example.com/good.mp4' : '',
    httpHeaders: const <String, String>{},
  );

  @override
  Future<PlaybackCatalog> getPlaybackCatalog(String seriesId) async =>
      PlaybackCatalog.empty;

  @override
  Future<List<Series>> search(
    String query, {
    bool enhanceWithBgm = true,
  }) async => const [];

  @override
  Future<void> startPlaybackKeepAlive(String mediaUrl) async {
    starts++;
    lastMediaUrl = mediaUrl;
  }

  @override
  void stopPlaybackKeepAlive() {
    stops++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('content', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      configureTestServices();
    });
    test(
      'session owns selection and metadata without mutating the handoff',
      () async {
        final legacy = <String, dynamic>{
          'source': '_local',
          'title': 'One',
          'videoList': ['First\$first.mp4', 'Second\$second.mp4'],
          'currPlayIndex': 0,
          'currUrl': 1,
        };
        final handoff = PlaybackRequest.fromMap(legacy);
        final content = PlaybackContent(
          request: handoff,
          sources: sourceRepository,
          collections: collections,
          history: historyRepository,
        );
        addTearDown(content.dispose);
        content.applySelection((episodeIndex: 1, lineIndex: 1));
        expect(content.videoList, same(handoff.episodes));
        expect(content.currPlayIndex, 1);
        expect(handoff.episodeIndex, 0);
        expect(legacy['currPlayIndex'], 0);
        expect(content.data.containsKey('videoList'), isFalse);
        expect(content.data.containsKey('currPlayIndex'), isFalse);
        expect(
          () => content.data['title'] = 'mutation',
          throwsUnsupportedError,
        );
        final projection = content.buildLegacyData()..['title'] = 'view only';
        expect(projection['currPlayIndex'], 1);
        expect(content.title, 'One');
        content.adoptPlaybackRequest(
          PlaybackRequest(
            source: '_local',
            metadata: const {'title': 'Two'},
            episodes: const [
              PlaybackEpisode(title: 'New', lines: ['new.mp4']),
            ],
          ),
        );
        expect(content.localFilePath, 'new.mp4');
        expect(content.title, 'Two');
        expect(content.request.prefetched, isNull);
      },
    );
    test(
      'local serialized catalog keeps every episode after loading',
      () async {
        final content = PlaybackContent(
          sources: sourceRepository,
          collections: collections,
          history: historyRepository,
          request: PlaybackRequest.fromMap({
            'source': '_local',
            'localFilePath': 'first.mp4',
            'videoList': ['First\$first.mp4', 'Second\$second.mp4'],
            'currPlayIndex': 1,
          }),
        );
        addTearDown(content.dispose);
        await content.loadDetail();
        expect(content.videoList, hasLength(2));
        expect(content.localFilePath, 'second.mp4');
      },
    );
    test(
      'local danmaku uses explicit file then sidecar, including remote media',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'player-danmaku-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final video = '${directory.path}${Platform.pathSeparator}episode.mp4';
        final explicit = File(
          '${directory.path}${Platform.pathSeparator}explicit.json',
        );
        final sidecar = File('${video}_danmaku.json');
        await explicit.writeAsString('[{"p":"1,1,16777215","m":"explicit"}]');
        await sidecar.writeAsString('[{"p":"2,1,16777215","m":"sidecar"}]');
        final data = <String, dynamic>{
          'source': '_local',
          'localFilePath': video,
          'danmakuPath': explicit.path,
        };
        final content = PlaybackContent(
          sources: sourceRepository,
          collections: collections,
          history: historyRepository,
          request: PlaybackRequest.fromMap(data),
        );
        addTearDown(content.dispose);
        expect((await content.fetchDanmakuData(0)).single.text, 'explicit');
        content.adoptPlaybackRequest(
          PlaybackRequest.fromMap({
            ...data,
            'localFilePath': 'https://example.test/episode.mp4',
          }),
        );
        expect((await content.fetchDanmakuData(0)).single.text, 'explicit');
        await explicit.delete();
        expect(await content.fetchDanmakuData(0), isEmpty);
        content.adoptPlaybackRequest(PlaybackRequest.fromMap(data));
        expect((await content.fetchDanmakuData(0)).single.text, 'sidecar');
        await sidecar.delete();
        expect(await content.fetchDanmakuData(0), isEmpty);
      },
    );
    test(
      'prefetched media is reused and invalidated by selection and source',
      () async {
        final request = PlaybackRequest(
          source: 'fixture',
          metadata: {'title': 'Example'},
        );
        final episodes = [
          const PlaybackEpisode(title: 'Episode', lines: ['first', 'second']),
        ];
        request.storePrefetched(
          episodeIndex: 0,
          lineIndex: 1,
          episodeId: 'first',
          url: 'https://fixture.test/prefetched.mp4',
          httpHeaders: const {'Referer': 'https://fixture.test'},
        );
        final service = PlaybackContent(
          sources: sourceRepository,
          collections: collections,
          history: historyRepository,
          request: request,
        );
        service.syncVideoData(episodes);
        final adapter = _KeepAliveAdapter();
        final media = await service.resolveAdapterPlaybackMedia(
          adapter,
          'first',
        );
        expect(media.url, 'https://fixture.test/prefetched.mp4');
        expect(media.httpHeaders['Referer'], 'https://fixture.test');
        service.applySelection((episodeIndex: 0, lineIndex: 2));
        expect(service.request.prefetched, isNull);
        request.storePrefetched(
          episodeIndex: 0,
          lineIndex: 2,
          episodeId: 'second',
          url: 'https://fixture.test/prefetched.mp4',
          httpHeaders: const {},
        );
        service.adoptPlaybackRequest(
          PlaybackRequest(source: 'another', episodes: episodes),
        );
        expect(service.request.prefetched, isNull);
      },
    );

    test(
      'player service keeps typed episodes and clamps line selection',
      () async {
        final data = <String, Object>{
          'source': 'internal',
          'videos': '01. 正片\$line-a\n1 正片\$line-b\n02. 下一集\$line-c',
        };
        final service = PlaybackContent(
          sources: sourceRepository,
          collections: collections,
          history: historyRepository,
          request: PlaybackRequest.fromMap(data),
        );
        await service.loadDetail();
        final episodes = service.videoList;

        expect(episodes, hasLength(2));
        expect(episodes.first.title, '01. 正片');
        expect(episodes.first.lines, ['line-a', 'line-b']);
        service.syncVideoData(
          episodes,
          preferredEpisodeIndex: 99,
          preferredLineIndex: 9,
        );
        expect(service.currPlayIndex, 1);
        expect(service.currUrl, 1);
        expect(service.currentVideoItem, isA<PlaybackEpisode>());
      },
    );

    test('line switch changes typed selection without reparsing data', () {
      final service = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: PlaybackRequest.fromMap(<String, Object>{
          'source': 'internal',
        }),
      );
      service.syncVideoData(const [
        PlaybackEpisode(title: '第一集', lines: ['a', 'b']),
        PlaybackEpisode(title: '第二集', lines: ['c']),
      ]);

      service.applySelection(service.normalizeSelection(0, 2));
      expect(service.currentEpisodeId, 'b');
      // 同集同线路的归一化结果与当前状态相同，调用方据此判等即可跳过切换
      final repeated = service.normalizeSelection(0, 2);
      expect(repeated.episodeIndex, service.currPlayIndex);
      expect(repeated.lineIndex, service.currUrl);
      service.applySelection(service.normalizeSelection(1, 2));
      expect(service.currUrl, 1);
      expect(service.currentEpisodeId, 'c');
    });

    test('legacy catalog parses line selection and skips blank entries', () {
      final data = <String, dynamic>{
        'videos': 'ep1\$a1\$a2\nep2\$first\$second\$third\n\nep3\$c1',
      };

      expect(PlaybackEpisodeCatalog.countFrom(data), 3);

      final episodes = PlaybackEpisodeCatalog.episodesOf(data);
      expect(episodes, hasLength(3));
      final episode = episodes[1];
      expect(episode.title, 'ep2');
      expect(episode.lineCount, 3);
      expect(episode.lineAt(1), 'first');
      expect(episode.lineAt(2), 'second');
      expect(episode.lineAt(3), 'third');
      expect(episode.lineAt(4), isNull);
    });

    test(
      'typed episode selection reuses objects and mixed lists skip blanks',
      () {
        const first = PlaybackEpisode(title: 'First', lines: ['a', 'b']);
        const second = PlaybackEpisode(title: 'Second', lines: ['c']);
        final data = {
          'videoList': [first, second],
        };
        expect(
          PlaybackEpisodeCatalog.episodesOf(data),
          same(data['videoList']),
        );
        final mixed = {
          'videoList': <Object>[' ', first, 7, 'Second\$c'],
        };
        final parsed = PlaybackEpisodeCatalog.episodesOf(mixed);
        expect(parsed, hasLength(2));
        expect(parsed[0], same(first));
        expect(parsed[1].lines, ['c']);
        final merged = PlaybackEpisodeCatalog.parse([
          '1 Same\$a',
          '2 Same\$b',
          '3 Same\$c',
        ], mergeDuplicateTitles: true);
        expect(merged.single.title, '1 Same');
        expect(merged.single.lines, ['a', 'b', 'c']);
      },
    );

    test(
      'blank legacy lists fall back to videos; typed lists stay authoritative',
      () {
        final data = <String, dynamic>{
          'videoList': ['', 'ep1\$a', '   ', 'ep2\$b'],
        };

        expect(PlaybackEpisodeCatalog.countFrom(data), 2);
        expect(PlaybackEpisodeCatalog.episodesOf(data).last.title, 'ep2');
        data['videoList'] = [' ', 7];
        data['videos'] = 'ep3\$c';
        expect(PlaybackEpisodeCatalog.episodesOf(data).single.title, 'ep3');
        data['videoList'] = <PlaybackEpisode>[];
        expect(PlaybackEpisodeCatalog.episodesOf(data), isEmpty);
      },
    );

    test('playback keep-alive follows the active media lifecycle', () async {
      final service = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: PlaybackRequest.fromMap(<String, Object>{
          'source': 'internal',
        }),
      );
      final adapter = _KeepAliveAdapter();

      final first = await service.startAdapterPlaybackKeepAlive(
        adapter,
        'https://example.com/first.m3u8',
      );
      final second = await service.startAdapterPlaybackKeepAlive(
        adapter,
        'https://example.com/second.m3u8',
      );

      expect(adapter.starts, 2);
      expect(adapter.stops, 1);
      expect(adapter.lastMediaUrl, 'https://example.com/second.m3u8');

      service.stopAdapterPlaybackKeepAlive(first);
      expect(
        adapter.stops,
        1,
        reason: 'stale playback must not stop the new one',
      );

      service.stopAdapterPlaybackKeepAlive(second);
      expect(adapter.stops, 2);
      service.dispose();
    });

    test('validated source falls back to another playback line', () async {
      final service = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: PlaybackRequest.fromMap(<String, Object>{
          'source': 'internal',
        }),
      );
      service.syncVideoData(const [
        PlaybackEpisode(title: 'Episode', lines: ['blocked', 'good']),
      ]);

      final media = await service.resolveAdapterPlaybackMedia(
        _KeepAliveAdapter(),
        'blocked',
      );

      expect(media.url, 'https://example.com/good.mp4');
      expect(service.currUrl, 2);
      service.dispose();
    });

    test(
      'local source preserves multi-episode videoList and updates selection',
      () async {
        final episodes = [
          const PlaybackEpisode(
            title: '第 01 话',
            lines: ['https://dav.test/ep01.mp4'],
          ),
          const PlaybackEpisode(
            title: '第 02 话',
            lines: ['https://dav.test/ep02.mp4'],
          ),
          const PlaybackEpisode(
            title: '第 03 话',
            lines: ['https://dav.test/ep03.mp4'],
          ),
        ];

        final service = PlaybackContent(
          sources: sourceRepository,
          collections: collections,
          history: historyRepository,
          request: PlaybackRequest.fromMap(<String, Object>{
            'source': '_local',
            'title': '测试番剧',
            'videoList': episodes,
            'currPlayIndex': 1,
          }),
        );

        await service.loadDetail();

        expect(service.isLocalSource, isTrue);
        expect(service.videoList, hasLength(3));
        expect(service.currPlayIndex, 1);
        expect(service.currentEpisodeTitle, '第 02 话');
        expect(service.localFilePath, 'https://dav.test/ep02.mp4');
        expect(await service.resolveEpisodeUrl(2), 'https://dav.test/ep03.mp4');

        service.applySelection(service.normalizeSelection(2, 1));
        expect(service.currPlayIndex, 2);
        expect(service.currentEpisodeTitle, '第 03 话');
        expect(service.localFilePath, 'https://dav.test/ep03.mp4');
      },
    );
  });

  group('legacy episodes', () {
    test('parses a legacy episode once and selects one-based lines', () {
      final episode = PlaybackEpisode.parse('第1话\$line-a\$line-b')!;
      expect(episode.title, '第1话');
      expect(episode.lineCount, 2);
      expect(episode.lineAt(1), 'line-a');
      expect(episode.lineAt(2), 'line-b');
      expect(episode.lineAt(0), isNull);
      expect(episode.serialize(), '第1话\$line-a\$line-b');
    });

    test('merges duplicate legacy titles while preserving line order', () {
      final episodes = PlaybackEpisodeCatalog.parse([
        '01. 正片\$a',
        '02. 下一话\$b',
        '1 正片\$c',
      ], mergeDuplicateTitles: true);
      expect(episodes, hasLength(2));
      expect(episodes.first.title, '01. 正片');
      expect(episodes.first.lines, ['a', 'c']);
    });

    test('filters typed episodes without reparsing serialized strings', () {
      final episodes = PlaybackEpisodeCatalog.parse([
        '第一话\$a',
        '第二话\$b',
        '特别篇\$c',
      ]);
      expect(
        PlaybackEpisodeCatalog.filterIndexes(
          episodes,
          ascending: true,
          searchQuery: '二',
        ),
        [1],
      );
      expect(PlaybackEpisodeCatalog.filterIndexes(episodes, ascending: false), [
        2,
        1,
        0,
      ]);
    });
  });
}
