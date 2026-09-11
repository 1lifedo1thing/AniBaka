import 'dart:convert';
import 'dart:io';

import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/ai_rule_authoring_service.dart';
import 'package:baka/services/source/rule_validation_runner.dart';
import 'package:baka/services/source/site_probe_service.dart';
import 'package:baka/source/engine/rule_language_spec.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI provider resolves an OpenAI-compatible chat endpoint', () {
    const provider = AiProviderConfig(
      baseUrl: 'https://example.test/v1/',
      model: 'test-model',
    );
    expect(
      provider.chatCompletionsUri.toString(),
      'https://example.test/v1/chat/completions',
    );
  });

  test('rule language spec is the validator operation source of truth', () {
    expect(RuleValidator.knownOps, RuleLanguageSpec.knownOps);
    expect(RuleLanguageSpec.promptReference, contains('jsonEpisodes'));
    expect(RuleLanguageSpec.promptReference, contains('sniff'));
  });

  test('custom source retains media validation timeout in its pipeline', () {
    final config = CustomSourceConfig.fromJson({
      'format': 'anx-rule/2',
      'id': 'slow',
      'name': 'Slow',
      'baseUrl': 'https://example.test',
      'search': <dynamic>[],
      'detail': <dynamic>[],
      'play': <dynamic>[],
      'mediaValidationTimeoutMs': 9000,
    });
    expect(config.pipeline?['mediaValidationTimeoutMs'], 9000);
  });

  test('site probe blocks loopback targets before making a request', () async {
    final probe = SiteProbeService();
    addTearDown(probe.cancel);
    await expectLater(
      probe.execute(
        const SiteProbeRequest(method: 'GET', url: 'http://127.0.0.1/test'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'OpenAI-compatible connection test accepts structured content',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '{"ok":true}'},
              },
            ],
          }),
        );
        await request.response.close();
      });

      final service = AiRuleAuthoringService();
      await service.testConnection(
        AiProviderConfig(
          baseUrl: 'http://${server.address.host}:${server.port}/v1',
          model: 'fake',
        ),
      );
    },
  );

  test(
    'authoring loop probes, validates, and returns an unsaved rule',
    () async {
      final modelServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => modelServer.close(force: true));
      var calls = 0;
      modelServer.listen((request) async {
        await utf8.decoder.bind(request).join();
        calls++;
        final content = calls == 1
            ? jsonEncode({
                'action': 'abort',
                'summary': '常见地址暂时不可用。',
                'reasonZh': '站点无法访问。',
              })
            : calls == 2
            ? jsonEncode({
                'action': 'probe',
                'summary': '改用浏览器渲染检查真实页面结构。',
                'requests': [
                  {
                    'method': 'GET',
                    'url': 'https://anime.example/search',
                    'render': true,
                  },
                ],
              })
            : jsonEncode({
                'action': 'candidate',
                'summary': '已找到可验证的搜索和播放流程。',
                'rule': {
                  'name': 'AI Test',
                  'baseUrl': 'https://ignored.example',
                  'pipeline': {
                    'search': <dynamic>[],
                    'detail': <dynamic>[],
                    'play': <dynamic>[],
                  },
                },
              });
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': content},
              },
            ],
          }),
        );
        await request.response.close();
      });

      final service = AiRuleAuthoringService(
        probeService: _FakeProbeService(),
        validationRunner: _SuccessfulValidationRunner(),
        uriValidator: (_) async {},
        includeBundledExamples: false,
      );
      addTearDown(service.cancel);
      final progress = <RuleAuthoringProgress>[];
      final result = await service.run(
        provider: AiProviderConfig(
          baseUrl: 'http://${modelServer.address.host}:${modelServer.port}/v1',
          model: 'fake',
        ),
        seed: const RuleAuthoringSeed(
          mode: RuleAuthoringMode.create,
          siteUrl: 'https://anime.example',
          keyword: '孤独摇滚',
        ),
        onProgress: progress.add,
      );

      expect(calls, 3);
      expect(result.config.baseUrl, 'https://anime.example');
      expect(result.config.id, startsWith('ai_anime_example_'));
      expect(
        progress.map((item) => item.stage),
        containsAll(['summary', 'probe', 'success']),
      );
    },
  );

  test(
    'validation runner reads actual MP4 bytes after rule execution',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final origin = 'http://${server.address.host}:${server.port}';
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        switch (request.uri.path) {
          case '/search':
            request.response.write(
              jsonEncode({
                'list': [
                  {'id': '1', 'name': '孤独摇滚'},
                ],
              }),
            );
            break;
          case '/detail/1':
            request.response.write(
              jsonEncode({
                'data': {
                  'episodes': [
                    {'episodeId': '$origin/video.mp4', 'episodeLabel': '第1集'},
                  ],
                },
              }),
            );
            break;
          case '/video.mp4':
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.contentType = ContentType.binary;
            if (request.method != 'HEAD') {
              request.response.add(List.filled(32, 1));
            }
            break;
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final config = CustomSourceConfig(
        id: 'local-test',
        name: 'Local test',
        baseUrl: origin,
        pipeline: _pipeline(),
      );
      final report = await RuleValidationRunner(
        mediaClient: Dio(BaseOptions(validateStatus: (_) => true)),
      ).validate(config, keyword: '孤独摇滚');

      expect(report.success, isTrue, reason: report.message);
      expect(report.mediaKind, 'file');
    },
  );

  test('validation runner fetches a real HLS media segment', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://${server.address.host}:${server.port}';
    var segmentRequests = 0;
    server.listen((request) async {
      switch (request.uri.path) {
        case '/search':
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'list': [
                {'id': '1', 'name': '孤独摇滚'},
              ],
            }),
          );
          break;
        case '/detail/1':
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': {
                'episodes': [
                  {'episodeId': '$origin/stream.m3u8', 'episodeLabel': '第1集'},
                ],
              },
            }),
          );
          break;
        case '/stream.m3u8':
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXTINF:5,\nsegment.ts\n#EXT-X-ENDLIST\n',
          );
          break;
        case '/segment.ts':
          segmentRequests++;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.add(List.filled(64, 2));
          break;
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final report = await RuleValidationRunner().validate(
      CustomSourceConfig(
        id: 'local-hls-test',
        name: 'Local HLS test',
        baseUrl: origin,
        pipeline: _pipeline(),
      ),
      keyword: '孤独摇滚',
    );

    expect(report.success, isTrue, reason: report.message);
    expect(report.mediaKind, 'hls-segment');
    expect(segmentRequests, greaterThan(0));
  });
}

Map<String, dynamic> _pipeline() => {
  'search': [
    {'op': 'fetch', 'url': '/search?wd={keyword}'},
    {
      'op': 'jsonSeries',
      'listPath': 'list',
      'detailUrlTemplate': '/detail/{id}',
    },
  ],
  'detail': [
    {'op': 'follow'},
    {
      'op': 'jsonEpisodes',
      'episodesPath': 'data.episodes',
      'episodeNameKey': 'episodeLabel',
      'episodeIdTemplate': '{episodeId:raw}',
      'sourceName': '测试线路',
    },
  ],
  'play': <dynamic>[],
};

class _FakeProbeService extends SiteProbeService {
  @override
  Future<Map<String, dynamic>> execute(SiteProbeRequest request) async => {
    'request': {'method': request.method, 'url': request.url},
    'status': 200,
    'finalUrl': request.url,
    'contentType': 'text/html',
    'headers': <String, String>{},
    'body': '<a href="/detail/1">孤独摇滚</a>',
    'truncated': false,
  };
}

class _SuccessfulValidationRunner extends RuleValidationRunner {
  @override
  Future<RuleValidationReport> validate(
    CustomSourceConfig config, {
    required String keyword,
    String? preferredSeriesId,
    String? preferredEpisodeId,
  }) async => const RuleValidationReport(
    success: true,
    stage: 'media',
    message: 'ok',
    seriesCount: 1,
    lineCount: 1,
    episodeCount: 1,
    mediaKind: 'file',
  );
}
