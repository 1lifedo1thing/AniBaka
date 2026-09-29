import 'dart:convert';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'rule_engine_test.dart' show FakeHost;

SourceRule rule({
  List<PipelineStep> search = const [],
  List<PipelineStep> detail = const [],
  List<PipelineStep> play = const [],
}) => SourceRule(
  id: 'fixture',
  name: 'Fixture',
  baseUrl: 'https://example.com',
  search: search,
  detail: detail,
  play: play,
);

class _HtmlHost extends FakeHost {
  _HtmlHost() : super({});
  @override
  bool get allowWebview => true;
  @override
  Future<String> renderWithWebview(
    String url, {
    bool Function(String)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 1),
  }) async {
    expect(isReady!('episode-2026'), isTrue);
    expect(isReady('episode-2'), isFalse);
    return 'episode-2026';
  }
}

void main() {
  const interpreter = PipelineInterpreter();
  test(
    'regex and replace preserve quantifiers alongside raw variables',
    () async {
      final source = rule(
        play: const [
          PipelineStep('template', {'value': 'episode-2026'}),
          PipelineStep('replace', {
            'pattern': r'\d{4}',
            'replacement': '1234',
            'regex': true,
          }),
          PipelineStep('regex', {
            'pattern': r'{episodeId:raw}-(\d{4})',
            'group': 1,
          }),
        ],
      );
      expect(RuleValidator.validate(source).isValid, isTrue);
      expect(
        await interpreter.runPlay(source, FakeHost({}), 'episode'),
        '1234',
      );
      expect(
        PipelineInterpreter.renderTemplate(
          r'\d{2,4} {episodeId:raw}',
          (_) => 'episode',
        ),
        r'\d{2,4} episode',
      );
    },
  );
  test('WebView readiness preserves exact numeric quantifiers', () async {
    await interpreter.runPlay(
      rule(
        play: const [
          PipelineStep('sniff', {
            'goal': 'html',
            'url': '/page',
            'readyRegex': r'^{episodeId:raw}-\d{4}$',
          }),
        ],
      ),
      _HtmlHost(),
      'episode',
    );
  });

  for (final first in [
    [
      {'id': '1', 'name': 'zzzz'},
    ],
    [
      {'name': 'naruto'},
    ],
    [
      {'id': '1', 'name': ''},
    ],
  ]) {
    test(
      'MacCMS retries when first nonempty list has no usable series: $first',
      () async {
        final host = FakeHost({
          'https://example.com/index.php/ajax/suggest?mid=1&wd=naruto&limit=20':
              jsonEncode({'list': first}),
          'https://example.com/ajax/suggest?mid=1&wd=naruto&limit=20':
              '{"list":[{"id":"2","name":"naruto"}]}',
        });
        final results = await interpreter.runSearch(
          rule(search: const [PipelineStep('maccmsSuggest', {})]),
          host,
          'naruto',
        );
        expect(results.single.seriesId, '2');
        expect(host.fetched, hasLength(2));
      },
    );
  }
  test('MacCMS valid first result does not request fallback', () async {
    final host = FakeHost({
      'https://example.com/index.php/ajax/suggest?mid=1&wd=naruto&limit=20':
          '{"list":[{"id":"2","name":"naruto"}]}',
    });
    expect(
      await interpreter.runSearch(
        rule(search: const [PipelineStep('maccmsSuggest', {})]),
        host,
        'naruto',
      ),
      hasLength(1),
    );
    expect(host.fetched, hasLength(1));
  });
  test('invalid episode ids do not suppress detail fallback', () async {
    final host = FakeHost({
      'https://example.com/bad':
          '{"episodes":[{"name":"missing"},{"id":null},{"id":"  "}]}',
      'https://example.com/good':
          '{"episodes":[{"id":"valid","name":"episode"}]}',
    });
    final result = await interpreter.runDetail(
      rule(
        detail: const [
          PipelineStep.first([
            [
              PipelineStep('fetch', {'url': '/bad'}),
              PipelineStep('jsonEpisodes', {'episodesPath': 'episodes'}),
            ],
            [
              PipelineStep('fetch', {'url': '/good'}),
              PipelineStep('jsonEpisodes', {'episodesPath': 'episodes'}),
            ],
          ]),
        ],
      ),
      host,
      '/series',
    );
    expect(result.single.episodes.single.episodeId, 'valid');
    expect(host.fetched, hasLength(2));
  });
  test('cancelled delay never enters following fetch or fallback', () async {
    final host = FakeHost({});
    final operation = SourceOperation();
    final work = interpreter.runSearch(
      rule(
        search: const [
          PipelineStep('delay', {'ms': 10000}),
          PipelineStep('fetch', {'url': '/obsolete'}),
        ],
      ),
      host,
      'query',
      operation: operation,
    );
    final failure = expectLater(
      work,
      throwsA(isA<RequestCancelledException>()),
    );
    operation.cancel();
    await failure;
    expect(host.fetched, isEmpty);
    operation.close();
  });
}
