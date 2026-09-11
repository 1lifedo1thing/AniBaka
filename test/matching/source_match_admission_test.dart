import 'package:baka/services/matching/source_match_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('rejects season and severe episode conflicts from the probe queue', () {
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
  });

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

  test('keeps the auto-match timing inside a bounded budget', () {
    // 结果一到就探 + 硬截止是唯一的兜底：预算必须落在硬截止之内，
    // 否则「给出结论」会晚于单个候选的解析时间。
    expect(
      SourceMatchEngine.candidateBudget,
      lessThan(SourceMatchEngine.hardDeadline),
    );
    expect(
      SourceMatchEngine.sourceSearchBudget.inMilliseconds,
      lessThanOrEqualTo(SourceMatchEngine.hardDeadline.inMilliseconds),
    );
    expect(SourceMatchEngine.maxAutoProbes, greaterThan(0));
    expect(SourceMatchEngine.raceProbesPerSource, greaterThan(0));
    expect(
      SourceMatchEngine.raceProbesPerSource,
      lessThanOrEqualTo(SourceMatchEngine.maxAutoProbes),
    );
  });
}
