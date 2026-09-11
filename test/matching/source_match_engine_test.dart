import 'package:flutter_test/flutter_test.dart';

import 'package:baka/services/matching/source_match_engine.dart';

void main() {
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

  test('penalizes package resources that greatly exceed BGM episode count', () {
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
  });

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

  test('exposes a single probe admission tier', () {
    final context = SourceMatchContext(primaryTitle: 'Example 第二季');
    final ranked = engine.rank([
      candidate('exact', 'Example 第二季', source: 's1', episodes: 12),
    ], context);

    expect(ranked.first.shouldProbeImmediately, isTrue);
  });

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

  test('auto match without aliases does not invent a fallback pass', () {
    final plan = SourceMatchEngine.planKeywords(
      autoMatch: true,
      titles: const ['Example'],
    );

    expect(plan.race, ['Example']);
    expect(plan.fallback, isEmpty);
  });

  test('manual search races several keywords and keeps the rest in reserve', () {
    final plan = SourceMatchEngine.planKeywords(
      autoMatch: false,
      titles: const ['Example', 'Example 2', 'Example 3', 'Example 4'],
    );

    expect(
      plan.race,
      hasLength(SourceMatchEngine.keywordsPerSourceManual),
    );
    expect(plan.fallback, ['Example 3', 'Example 4']);
  });

  test('an empty title list produces no keyword work', () {
    expect(
      SourceMatchEngine.planKeywords(autoMatch: true, titles: const []).isEmpty,
      isTrue,
    );
    expect(
      SourceMatchEngine.planKeywords(autoMatch: false, titles: const [])
          .isEmpty,
      isTrue,
    );
  });
}
