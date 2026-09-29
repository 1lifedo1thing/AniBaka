import 'package:baka/models/playback_request.dart';
import 'package:baka/source/models/source_search_result.dart';
import 'dart:async';
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
        SourceSearchResult.fromLegacy({
          'title': 'Example',
          'source': 'internal',
          ...{'id': 1},
        }),
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

  test('a timed-out media resolve keeps the candidate usable', () async {
    final controller = _SlowMediaController();
    addTearDown(controller.dispose);
    final item = SearchResultItem(
      SourceSearchResult.fromLegacy({
        'title': 'Example',
        'source': 'test',
        ...{'seriesId': 'example'},
      }),
    );

    final probe = await controller.ensureCandidatePlayable(
      item,
      episodeIndex: 0,
      preferredLine: 1,
      resolveMedia: true,
      raceMode: true,
    );

    // The catalog stays usable while the media result is pending.
    expect(probe.status, SourceProbeStatus.playable);
    expect(probe.isReady, isTrue);
    expect(probe.isInstantPlayable, isFalse);

    // 慢解析回来后自动补记为可即播，并写入预取。
    final ready = Completer<void>();
    void onChanged() {
      if (probe.isInstantPlayable && !ready.isCompleted) ready.complete();
    }

    controller.addListener(onChanged);
    addTearDown(() => controller.removeListener(onChanged));
    controller.release.complete();
    await ready.future.timeout(const Duration(seconds: 5));
    expect(probe.status, SourceProbeStatus.direct);
    expect(probe.isInstantPlayable, isTrue);
    expect(probe.mediaUrl, 'https://cdn.example.com/temp/2607/01.mp4');
    expect(probe.resolvedLineIndex, 1);
  });

  test('keeps the probe window full after one route is verified', () {
    final controller = _ProbeCountingController();
    addTearDown(controller.dispose);
    final candidates = <SourceCandidateState>[];

    for (var index = 0; index < 5; index++) {
      final item = SearchResultItem(
        SourceSearchResult.fromLegacy({
          'title': 'Example $index',
          'source': 'test',
          ...{'seriesId': '$index'},
        }),
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
  Future<PlaybackRequest> resolveVideoData(SearchResultItem item) async {
    loads++;
    return PlaybackRequest.fromMap({
      'source': 'internal',
      'videos': 'Episode\$https://fixture.test/episode.mp4',
    });
  }
}

class _SlowMediaController extends VideoSourceSearchController {
  _SlowMediaController() : super(title: 'Example');

  final release = Completer<void>();

  // Keep the media pending until the test releases it.
  @override
  Duration get raceMediaTimeout => const Duration(milliseconds: 20);

  @override
  Future<PlaybackRequest> resolveVideoData(SearchResultItem item) async =>
      PlaybackRequest.fromMap({
        'source': 'test',
        'videos': '第1集\$line-token-1',
      });

  @override
  Future<({String url, Map<String, String> httpHeaders})> resolveLineMedia({
    required String sourceKey,
    required String lineToken,
    bool raceMode = false,
  }) async {
    await release.future;
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
