import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/store/bundled_rule_store.dart';

void main() {
  final assetDirectory = Directory('assets/rules');
  final assetFiles = assetDirectory
      .listSync()
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.json'))
      .toList(growable: false);

  test('all built-in assets contain valid v2 pipeline rules', () {
    for (final file in assetFiles) {
      final name = file.uri.pathSegments.last;
      final decoded = SourceCodec.decode(file.readAsStringSync().trim());
      expect(decoded, isA<Map>(), reason: '$name must contain a JSON object');

      final config = CustomSourceConfig.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      );
      expect(
        BundledRuleStore.builtinAssets[config.id],
        file.path.replaceAll(r'\', '/'),
        reason: '$name registry mismatch',
      );
      expect(config.baseUrl, isNotEmpty, reason: '$name missing baseUrl');

      final validation = RuleValidator.validate(config.toSourceRule());
      expect(
        validation.isValid,
        isTrue,
        reason: '$name invalid: ${validation.errors.join('; ')}',
      );
    }
  });

  test('silisili rule parses gated search results and playback lines', () {
    final path = BundledRuleStore.builtinAssets['silisili']!;
    final rule = SourceRule.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(File(path).readAsStringSync()) as Map,
      ),
    );
    final adapter = PipelineSourceAdapter(rule);

    final results = adapter.parseSearchList(
      '''
      <main id="content">
        <article>
          <a href="/voddetail/h077777Z/" title="无职转生 第二季">
            <img data-original="/upload/wuzhi.jpg" alt="无职转生 第二季">
          </a>
        </article>
      </main>
      ''',
      selectors: rule.search[1].strList('selectors'),
      detailPattern: rule.search[1].str('detailPattern'),
    );
    expect(results, hasLength(1));
    expect(results.single.name, '无职转生 第二季');
    expect(
      results.single.seriesId,
      'https://www.silisilifun.com/voddetail/h077777Z/',
    );

    final sources = adapter.parseEpisodes(
      '''
      <section class="play-pannel-box">
        <div class="play-pannel_hd"><h3 class="widget-title">No.X</h3></div>
        <div class="play-pannel-list">
          <ul class="stui-content__playlist">
            <li><a href="/vodplay/h077777Z/3/1/">第1话</a></li>
            <li><a href="/vodplay/h077777Z/3/2/">第2话</a></li>
          </ul>
        </div>
      </section>
      <section class="play-pannel-box">
        <div class="play-pannel_hd"><h3 class="widget-title">NO.F</h3></div>
        <div class="play-pannel-list">
          <ul class="stui-content__playlist">
            <li><a href="/vodplay/h077777Z/2/1/">第1话</a></li>
          </ul>
        </div>
      </section>
      ''',
      listSelectors: rule.detail[1].strList('listSelectors'),
      tabSelectors: rule.detail[1].strList('tabSelectors'),
    );
    expect(sources, hasLength(2));
    expect(sources.map((source) => source.sourceName), ['No.X', 'NO.F']);
    expect(sources.first.episodes, hasLength(2));
    expect(
      sources.first.episodes.first.episodeId,
      'https://www.silisilifun.com/vodplay/h077777Z/3/1/',
    );

    adapter.dispose();
  });
}
