import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:baka/instance.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/matching/media_readiness.dart';
import 'package:baka/services/matching/probe_scheduler.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/utils/substring_matcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ranking', () {
    const engine = SourceMatchEngine();

    SourceMatchCandidate candidate(
      String key,
      String title, {
      required String source,
      required int episodes,
    }) {
      return SourceMatchCandidate(
        key: key,
        title: title,
        sourceType: source,
        data: {
          'title': title,
          'videoList': List<String>.generate(
            episodes,
            (index) => '${index + 1}#episode-${index + 1}',
            growable: false,
          ),
        },
      );
    }

    test('prefers the matching season with the expected episode count', () {
      final context = SourceMatchContext(
        primaryTitle: 'Example 第二季',
        bgmEpisodeCount: 24,
        bgmCompleted: true,
        querySeason: 2,
      );

      final ranked = engine.rank([
        candidate('a', 'Example', source: 'source_a', episodes: 12),
        candidate('b', 'Example 第二季', source: 'source_b', episodes: 24),
      ], context);

      expect(ranked.first.candidate.key, 'b');
      expect(ranked.first.confidence, greaterThanOrEqualTo(0.8));
      expect(ranked.last.seasonConflict, isFalse);
      expect(ranked.first.score, greaterThan(ranked.last.score));
    });

    test('penalizes movie candidates when BGM expects a TV season', () {
      final context = SourceMatchContext(
        primaryTitle: 'Example',
        bgmEpisodeCount: 12,
        bgmCompleted: true,
      );

      final ranked = engine.rank([
        candidate('movie', 'Example 剧场版', source: 'source_a', episodes: 1),
        candidate('tv', 'Example TV', source: 'source_b', episodes: 12),
      ], context);

      expect(ranked.first.candidate.key, 'tv');
      expect(
        ranked.first.score,
        greaterThan(ranked.firstWhere((s) => s.candidate.key == 'movie').score),
      );
    });

    test(
      'penalizes package resources that greatly exceed BGM episode count',
      () {
        final context = SourceMatchContext(
          primaryTitle: 'Example',
          bgmEpisodeCount: 12,
          bgmCompleted: true,
        );

        final ranked = engine.rank([
          candidate('pack', 'Example 合集', source: 'source_a', episodes: 48),
          candidate('single', 'Example', source: 'source_b', episodes: 12),
        ], context);

        final pack = ranked.firstWhere((s) => s.candidate.key == 'pack');
        expect(ranked.first.candidate.key, 'single');
        expect(pack.severeEpisodeConflict, isTrue);
        expect(pack.confidence, lessThan(0.70));
      },
    );

    test('penalizes title similarity when modifiers differ (movie vs tv)', () {
      final context = SourceMatchContext(primaryTitle: '海贼王');
      final ranked = engine.rank([
        candidate('movie', '海贼王 剧场版 红发歌姬', source: 's1', episodes: 1),
        candidate('tv', '海贼王', source: 's2', episodes: 1000),
      ], context);

      expect(ranked.first.candidate.key, 'tv');
      final movieScore = ranked.firstWhere((s) => s.candidate.key == 'movie');
      expect(movieScore.confidence, lessThan(0.70));
    });

    test(
      'caps confidence score strictly under 0.35 for severe episode conflict',
      () {
        final context = SourceMatchContext(
          primaryTitle: 'Test Anime',
          bgmEpisodeCount: 12,
          bgmCompleted: true,
        );

        final ranked = engine.rank([
          candidate('mismatch', 'Test Anime', source: 's1', episodes: 100),
        ], context);

        expect(ranked.first.severeEpisodeConflict, isTrue);
        expect(ranked.first.confidence, lessThanOrEqualTo(0.32));
        expect(ranked.first.shouldProbeImmediately, isFalse);
      },
    );

    test('counts video rows without allocating split substrings', () {
      final item = SourceMatchCandidate(
        key: 'videos',
        title: 'Example',
        sourceType: 'source',
        data: const {'videos': '  \r\n第1集\$ep-1\r\n\t\n第2集\$ep-2\n第3集\$ep-3'},
      );

      expect(item.episodeCount, 3);
    });

    test('auto match searches the primary title only', () {
      final plan = SourceMatchEngine.planKeywords(
        autoMatch: true,
        titles: const ['Example', 'Example 第二季', 'Example 2', 'ignored'],
      );

      // 只竞速主标题，没有任何回退轮次。
      expect(plan.race, ['Example']);
      expect(plan.fallback, isEmpty);
    });

    test(
      'manual search races several keywords and keeps the rest in reserve',
      () {
        final plan = SourceMatchEngine.planKeywords(
          autoMatch: false,
          titles: const ['Example', 'Example 2', 'Example 3', 'Example 4'],
        );

        expect(plan.race, hasLength(SourceMatchEngine.keywordsPerSourceManual));
        expect(plan.fallback, ['Example 3', 'Example 4']);
      },
    );

    test('an empty title list produces no keyword work', () {
      expect(
        SourceMatchEngine.planKeywords(
          autoMatch: true,
          titles: const [],
        ).isEmpty,
        isTrue,
      );
      expect(
        SourceMatchEngine.planKeywords(
          autoMatch: false,
          titles: const [],
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('admission', () {
    const engine = SourceMatchEngine();

    SourceMatchCandidate candidate(
      String key,
      String title, {
      required int episodes,
    }) => SourceMatchCandidate(
      key: key,
      title: title,
      sourceType: 'source',
      data: {
        'videoList': List<String>.generate(
          episodes,
          (index) => '${index + 1}#episode-${index + 1}',
          growable: false,
        ),
      },
    );

    test('admits an exact match into the probe queue', () {
      final score = engine.score(
        candidate('exact', 'Example', episodes: 12),
        SourceMatchContext(primaryTitle: 'Example', bgmEpisodeCount: 12),
      );

      expect(score.confidence, 1);
      expect(score.shouldProbeImmediately, isTrue);
    });

    test(
      'rejects season and severe episode conflicts from the probe queue',
      () {
        final season = engine.score(
          candidate('season', 'Example 第二季', episodes: 12),
          SourceMatchContext(primaryTitle: 'Example', querySeason: 1),
        );
        expect(season.seasonConflict, isTrue);
        expect(season.shouldProbeImmediately, isFalse);

        final pack = engine.score(
          candidate('pack', 'Example', episodes: 24),
          SourceMatchContext(
            primaryTitle: 'Example',
            bgmEpisodeCount: 12,
            bgmCompleted: true,
          ),
        );
        expect(pack.severeEpisodeConflict, isTrue);
        expect(pack.shouldProbeImmediately, isFalse);
      },
    );

    test('rejects unrelated titles from the probe queue', () {
      final score = engine.score(
        candidate('other', 'Totally Different Show', episodes: 12),
        SourceMatchContext(primaryTitle: 'Example'),
      );

      // 子串判定是唯一的相似度算法：不构成子串即 0 分。
      expect(score.titleSimilarity, 0);
      expect(
        score.confidence,
        lessThan(SourceMatchEngine.immediateProbeConfidence),
      );
      expect(score.shouldProbeImmediately, isFalse);
    });
  });

  test(
    'media readiness distinguishes media, torrents and unresolved pages',
    () {
      for (final (url, kind) in [
        ('https://cdn.example.com/ep1/index.m3u8', MediaTokenKind.directMedia),
        ('https://cdn.example.com/a.mp4?token=1', MediaTokenKind.directMedia),
        ('magnet:?xt=urn:btih:abcdef', MediaTokenKind.torrent),
        (
          'https://site.example.com/play/12345.html',
          MediaTokenKind.needsResolve,
        ),
        (
          'https://site.example.com/vod/detail/id/9',
          MediaTokenKind.needsResolve,
        ),
        ('/bangumi/12/episode/3', MediaTokenKind.needsResolve),
        ('ep-12-line-1', MediaTokenKind.needsResolve),
      ]) {
        expect(MediaReadiness.classify(url), kind, reason: url);
      }
      expect(
        MediaReadiness.isAcceptablePlaybackUrl(
          'https://cdn.example.com/hls/index.m3u8',
        ),
        isTrue,
      );
      expect(
        MediaReadiness.isAcceptablePlaybackUrl(
          'https://site.example.com/play/1.html',
        ),
        isFalse,
      );
      expect(MediaReadiness.isAcceptablePlaybackUrl(''), isFalse);
    },
  );

  group('match memory', () {
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
          (jsonDecode(Instances.sp.getString('match_memory_v1')!) as Map)
              .length,
          200,
        );
        await MatchMemoryService.remove(title: '', bgmId: 206);
        expect(MatchMemoryService.read(title: '', bgmId: 206), isNull);
      },
    );
  });

  group('probes', () {
    group('ProbeScheduler', () {
      test('runs jobs with bounded concurrency', () async {
        final started = <int>[];
        final gates = <int, Completer<void>>{};
        final scheduler = ProbeScheduler<int>(
          concurrency: 2,
          keyOf: (job) => '$job',
          run: (job) {
            started.add(job);
            return (gates[job] = Completer<void>()).future;
          },
        );

        for (var job = 1; job <= 5; job++) {
          expect(scheduler.add(job), isTrue);
        }
        expect(started, [1, 2]);
        expect(scheduler.activeCount, 2);
        expect(scheduler.queuedCount, 3);

        gates[1]!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(started, [1, 2, 3]);

        gates[2]!.complete();
        gates[3]!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(started, [1, 2, 3, 4, 5]);

        gates[4]!.complete();
        gates[5]!.complete();
        await scheduler.drained;
        expect(scheduler.isBusy, isFalse);
        expect(scheduler.activeCount, 0);
        expect(scheduler.queuedCount, 0);
      });

      test('accepts each key once per run and again after reset', () async {
        final runs = <String>[];
        final scheduler = ProbeScheduler<String>(
          concurrency: 2,
          keyOf: (job) => job,
          run: (job) async => runs.add(job),
        );

        expect(scheduler.add('a'), isTrue);
        expect(scheduler.add('a'), isFalse);
        expect(scheduler.contains('a'), isTrue);
        await scheduler.drained;
        expect(runs, ['a']);

        scheduler.reset();
        expect(scheduler.contains('a'), isFalse);
        expect(scheduler.add('a'), isTrue);
        await scheduler.drained;
        expect(runs, ['a', 'a']);
      });

      test(
        'close discards queued work and lets in-flight jobs settle',
        () async {
          final started = <int>[];
          final gate = Completer<void>();
          final scheduler = ProbeScheduler<int>(
            concurrency: 1,
            keyOf: (job) => '$job',
            run: (job) async {
              started.add(job);
              await gate.future;
            },
          );

          scheduler.add(1);
          scheduler.add(2);
          scheduler.close();
          expect(scheduler.isClosed, isTrue);
          expect(scheduler.add(3), isFalse);

          gate.complete();
          await scheduler.drained;
          expect(started, [1]);
          expect(scheduler.isBusy, isFalse);
        },
      );

      test('a failing job does not stop the remaining queue', () async {
        final runs = <int>[];
        final scheduler = ProbeScheduler<int>(
          concurrency: 2,
          keyOf: (job) => '$job',
          run: (job) async {
            if (job == 1) throw StateError('boom');
            runs.add(job);
          },
        );

        scheduler.add(1);
        scheduler.add(2);
        await scheduler.drained;
        expect(runs, [2]);
        expect(scheduler.isBusy, isFalse);
      });

      test('drained completes once and reports a fresh busy cycle', () async {
        final gate = Completer<void>();
        final scheduler = ProbeScheduler<int>(
          concurrency: 1,
          keyOf: (job) => '$job',
          run: (job) async => gate.future,
        );

        expect(scheduler.isBusy, isFalse);
        await scheduler.drained;

        scheduler.add(1);
        final first = scheduler.drained;
        gate.complete();
        await first;
        expect(scheduler.isBusy, isFalse);

        scheduler.add(2);
        scheduler.close();
        await scheduler.drained;
        expect(scheduler.isBusy, isFalse);
      });
    });
  });

  group('title matching', () {
    test('suffix links, overlaps, empty strings and UTF-16 match contains', () {
      final random = Random(42);
      const alphabet = ['a', 'b', 'c', '剧', '透', '😀'];
      String word(int length) => List.generate(
        length,
        (_) => alphabet[random.nextInt(alphabet.length)],
      ).join();
      for (var run = 0; run < 100; run++) {
        final words = List.generate(20, (_) => word(1 + random.nextInt(7)));
        if (run == 0) words.add('');
        final matcher = SubstringMatcher(words);
        for (var i = 0; i < 100; i++) {
          final text = word(random.nextInt(20));
          expect(
            matcher.matches(text),
            words.any(text.contains),
            reason: '$words / $text',
          );
        }
      }
    });

    test('controller replaces index only when words change and owns input', () {
      final controller = DanmakuController();
      final words = List.generate(20, (i) => 'word$i');
      controller.blockWords = words;
      words.clear();
      expect(controller.isBlocked('a word19 b'), isTrue);
      controller.removeBlockWord('word1');
      controller.removeBlockWord('word19');
      expect(controller.isBlocked('a word19 b'), isFalse);
      controller.addBlockWord('剧透');
      expect(controller.isBlocked('禁止剧透'), isTrue);
      controller.blockWords = const [];
      expect(controller.isBlocked('禁止剧透'), isFalse);
      controller.dispose();
      expect(controller.items, isEmpty);
      expect(controller.blockWords, isEmpty);
    });
  });
}
