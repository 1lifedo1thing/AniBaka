import '../support/app_dependencies.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baka/instance.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';

void main() {
  test(
    'concurrent catalog requests upgrade to media without fetching again',
    () async {
      final controller = _CatalogController();
      addTearDown(controller.dispose);
      final item = SearchResultItem(
        title: 'Example',
        sourceType: 'internal',
        data: {'id': 1},
      );
      final catalog = controller.ensureCandidatePlayable(
        item,
        episodeIndex: 0,
        preferredLine: 1,
        resolveMedia: false,
      );
      final media = controller.ensureCandidatePlayable(
        item,
        episodeIndex: 0,
        preferredLine: 1,
      );
      final first = await catalog;
      final resolved = await media;
      expect(controller.loads, 1);
      expect(identical(first, resolved), isTrue);
      expect(resolved.isInstantPlayable, isTrue);
      expect(resolved.mediaUrl, 'https://fixture.test/episode.mp4');
      expect(
        identical(
          await controller.ensureCandidatePlayable(
            item,
            episodeIndex: 0,
            preferredLine: 1,
          ),
          resolved,
        ),
        isTrue,
      );
      expect(controller.loads, 1);
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
  });

  tearDown(() {
    final cached = VideoSourceSearchController.globalCached;
    VideoSourceSearchController.globalCached = null;
    VideoSourceSearchController.globalCachedTitle = null;
    cached?.dispose();
  });

  test('shares the latest detail search controller with source switching', () {
    final detailController = VideoSourceSearchController(title: 'Example');
    final replacement = VideoSourceSearchController(title: 'Other');

    VideoSourceSearchController.cacheGlobal('Example', detailController);

    expect(
      identical(VideoSourceSearchController.globalCached, detailController),
      isTrue,
    );
    expect(detailController.isDisposed, isFalse);

    VideoSourceSearchController.cacheGlobal('Other', replacement);

    expect(detailController.isDisposed, isTrue);
    expect(
      identical(VideoSourceSearchController.globalCached, replacement),
      isTrue,
    );

    final taken = VideoSourceSearchController.takeSharedFor(title: 'Other');
    addTearDown(taken.dispose);
    expect(identical(taken, replacement), isTrue);
    expect(VideoSourceSearchController.globalCached, isNull);
  });

  test('reuses an already verified switch candidate', () async {
    final controller = VideoSourceSearchController(title: 'Example');
    addTearDown(controller.dispose);

    final item = SearchResultItem(
      title: 'Example',
      sourceType: 'test',
      data: const {'seriesId': 'example'},
    );
    final data = <String, dynamic>{'source': 'test'};
    final probe =
        SourceProbeState(item: item, episodeIndex: 3, preferredLine: 1)
          ..status = SourceProbeStatus.direct
          ..data = data
          ..resolvedLineIndex = 2;
    final candidate = SourceCandidateState(
      item: item,
      score: 100,
      probe: probe,
    );

    final resolved = await controller.resolveSwitchCandidate(candidate);

    expect(identical(resolved, probe), isTrue);
    expect(identical(resolved.data, data), isTrue);
    expect(resolved.resolvedLineIndex, 2);
  });

  test('a timed-out media resolve keeps the candidate usable', () async {
    final controller = _SlowMediaController();
    addTearDown(controller.dispose);
    final item = SearchResultItem(
      title: 'Example',
      sourceType: 'test',
      data: const {'seriesId': 'example'},
    );

    final probe = await controller.ensureCandidatePlayable(
      item,
      episodeIndex: 0,
      preferredLine: 1,
      resolveMedia: true,
      raceMode: true,
    );

    // 竞速预算（20ms）等不到 120ms 的解析：目录已就绪，源不能被判成不可用。
    expect(probe.status, SourceProbeStatus.playable);
    expect(probe.isReady, isTrue);
    expect(probe.isInstantPlayable, isFalse);

    // 慢解析回来后自动补记为可即播，并写入预取。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(probe.status, SourceProbeStatus.direct);
    expect(probe.isInstantPlayable, isTrue);
    expect(probe.mediaUrl, 'https://cdn.example.com/temp/2607/01.mp4');
    expect(probe.resolvedLineIndex, 1);
  });

  test('treats resolved non-direct candidates as selectable', () {
    final item = SearchResultItem(
      title: 'Example',
      sourceType: 'custom',
      data: const {'seriesId': 'example'},
    );
    final probe = SourceProbeState(
      item: item,
      episodeIndex: 0,
      preferredLine: 1,
    )..status = SourceProbeStatus.playable;
    final candidate = SourceCandidateState(
      item: item,
      score: 100,
      probe: probe,
    );
    final group = DirectSourceGroup(
      key: item.key,
      origins: [candidate],
      status: probe.status,
    );

    expect(group.isReady, isTrue);
  });

  test('keeps the probe window full after one route is verified', () {
    final controller = _ProbeCountingController();
    addTearDown(controller.dispose);
    final candidates = <SourceCandidateState>[];

    for (var index = 0; index < 5; index++) {
      final item = SearchResultItem(
        title: 'Example $index',
        sourceType: 'test',
        data: {'seriesId': '$index'},
      );
      final probe = SourceProbeState(
        item: item,
        episodeIndex: 0,
        preferredLine: 1,
      );
      controller.probes[item.key] = probe;
      candidates.add(
        SourceCandidateState(item: item, score: 5 - index, probe: probe),
      );
    }

    controller.startSwitchProbes(candidates);
    expect(controller.calls, 4);

    candidates.first.probe.status = SourceProbeStatus.direct;
    controller.startSwitchProbes(candidates);

    expect(controller.calls, 5);
    expect(candidates.last.status, SourceProbeStatus.resolving);
  });
}

class _CatalogController extends VideoSourceSearchController {
  _CatalogController() : super(title: 'Example');
  int loads = 0;
  @override
  Future<Map<String, dynamic>> resolveVideoData(SearchResultItem item) async {
    loads++;
    return {
      'source': 'internal',
      'videos': 'Episode\$https://fixture.test/episode.mp4',
    };
  }
}

class _SlowMediaController extends VideoSourceSearchController {
  _SlowMediaController() : super(title: 'Example');

  /// 竞速预算压到 20ms，让 120ms 的解析必定"超时"。
  @override
  Duration get raceMediaTimeout => const Duration(milliseconds: 20);

  @override
  Future<Map<String, dynamic>> resolveVideoData(SearchResultItem item) async => {
        'source': 'test',
        'videos': '第1集\$line-token-1',
      };

  @override
  Future<({String url, Map<String, String> httpHeaders})> resolveLineMedia({
    required String sourceKey,
    required String lineToken,
    bool raceMode = false,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return (
      url: 'https://cdn.example.com/temp/2607/01.mp4',
      httpHeaders: const <String, String>{},
    );
  }
}

class _ProbeCountingController extends VideoSourceSearchController {
  _ProbeCountingController() : super(title: 'Example');

  final probes = <String, SourceProbeState>{};
  int calls = 0;

  @override
  Future<SourceProbeState> ensureCandidatePlayable(
    SearchResultItem item, {
    required int episodeIndex,
    required int preferredLine,
    bool resolveMedia = true,
    bool raceMode = false,
  }) {
    calls++;
    final probe = probes[item.key]!..status = SourceProbeStatus.resolving;
    return Future.value(probe);
  }
}
