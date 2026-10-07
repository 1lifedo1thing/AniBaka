import 'package:baka/source/runtime/source_operation.dart';
import 'dart:convert';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/recipes.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:test/test.dart';

/// Stub only I/O; fixtures run through the same parsers as production.
class FakeHost implements PipelineHost {
  FakeHost(this.responses);
  final Map<String, String> responses;
  final List<String> fetched = [];

  @override
  bool get allowWebview => false;

  @override
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    SourceOperation? operation,
    RequestPriority priority = RequestPriority.search,
  }) async {
    fetched.add(url);
    return responses[url] ?? '';
  }

  @override
  Future<String> renderWithWebview(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = Duration.zero,
  }) async => '';
  @override
  Future<String> sniffWithWebview(String url) async => '';
}

class VerifyCheckHost extends FakeHost {
  VerifyCheckHost() : super(const {});

  var pageFetches = 0;
  String? verifyMethod;
  Object? verifyBody;
  String? verifyContentType;

  @override
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    SourceOperation? operation,
    RequestPriority priority = RequestPriority.search,
  }) async {
    fetched.add(url);
    if (url == 'https://example.com/index.php/ajax/verify_check?type=search') {
      verifyMethod = method;
      verifyBody = body;
      verifyContentType = contentType;
      return '{"code":1,"msg":"ok"}';
    }
    if (url == 'https://example.com/search/x') {
      pageFetches++;
      if (pageFetches == 1) {
        return '''
          <script>
            const key = new Uint8Array([0x4e, 0x3f, 0xa9, 0xc2]);
            MAC.Ajax('/index.php/ajax/verify_check?type=search', 'post');
          </script>
        ''';
      }
      return '<li><a href="/detail/1" title="verified">verified</a></li>';
    }
    return '';
  }
}

class _WebviewHost extends FakeHost {
  _WebviewHost(this.render, {Map<String, String> responses = const {}})
    : super(responses);

  final String Function(String, bool Function(String)?, Duration, Duration)
  render;

  @override
  bool get allowWebview => true;

  @override
  Future<String> renderWithWebview(
    String url, {
    bool Function(String)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = Duration.zero,
  }) async => render(url, isReady, timeout, settleDelay);
}

SourceRule _rule(List<Map<String, dynamic>> play) => SourceRule.fromJson({
  'format': kSourceRuleFormatV2,
  'id': 'test',
  'name': 'Test',
  'baseUrl': 'https://example.com',
  'search': const [],
  'detail': const [],
  'play': play,
  'useWebview': true,
});

SourceRule _pipelineRule({
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

void main() {
  test('rule edits isolate mutable input and survive persistence', () {
    final config = CustomSourceConfig.fromJson({
      'id': 'shared',
      'name': 'Shared',
      'baseUrl': 'https://example.test',
      'directConnection': true,
      'pipeline': {
        'headers': {'Referer': 'https://example.test'},
        'search': [
          {'op': 'template', 'value': '{keyword}'},
        ],
        'detail': [],
        'play': [
          {
            'op': 'first',
            'branches': [
              [
                {'op': 'template', 'value': 'video.mp4'},
              ],
            ],
          },
        ],
      },
    });
    final changed = config.copyWith(enabled: false, updatedAt: DateTime(2026));
    final renamed = changed.copyWith(name: 'Renamed');
    expect(() => renamed.rule.play.clear(), throwsUnsupportedError);
    final replacement = <PipelineStep>[const PipelineStep('follow', {})];
    final replaced = config.rule.copyWith(play: replacement);
    replacement.clear();
    expect(replaced.play.single.op, 'follow');
    expect(config.rule.play.single.branches.single.single.op, 'template');
    final restored = CustomSourceConfig.fromJson(
      jsonDecode(jsonEncode(renamed.toJson())) as Map<String, dynamic>,
    );
    expect(restored.rule.toJson(), renamed.rule.toJson());
    expect(restored.enabled, isFalse);
    expect(restored.updatedAt, DateTime(2026));
    expect(restored.rule.directConnection, isTrue);
  });

  group('pipeline', () {
    const interp = PipelineInterpreter();

    test(
      'JSON paths do not guess envelopes and alternatives are explicit',
      () async {
        const payload =
            '{"list":[{"id":"wrong","name":"Wrong"}],'
            '"data":{"list":[{"id":"right","name":"Right"}]}}';
        for (final (path, expected) in [
          ('missing', <String>[]),
          ('missing|data.list', ['right']),
          ('list', ['wrong']),
        ]) {
          final results = await interp.runSearch(
            _pipelineRule(
              search: [
                const PipelineStep('template', {'value': payload}),
                PipelineStep('jsonSeries', {'listPath': path}),
              ],
            ),
            FakeHost({}),
            'query',
          );
          expect(results.map((series) => series.seriesId), expected);
        }
        final result = await interp.runSearch(
          _pipelineRule(
            search: const [
              PipelineStep('template', {'value': payload}),
              PipelineStep('json', {'path': 'missing'}),
              PipelineStep('jsonSeries', {}),
            ],
          ),
          FakeHost({}),
          'query',
        );
        expect(result, isEmpty);
      },
    );

    test(
      'new responses replace decoded data without losing prior results',
      () async {
        final results = await interp.runSearch(
          _pipelineRule(
            search: const [
              PipelineStep('template', {
                'value': '[{"id":"1","name":"First"}]',
              }),
              PipelineStep('jsonSeries', {}),
              PipelineStep('jsonSeries', {}),
              PipelineStep('template', {
                'value': '[{"id":"2","name":"Second"}]',
              }),
              PipelineStep('jsonSeries', {}),
            ],
          ),
          FakeHost({}),
          'query',
        );
        expect(results.map((series) => series.name), ['First', 'Second']);
      },
    );

    test('missing CSS selectors advance to the declared branch', () async {
      final results = await interp.runSearch(
        _pipelineRule(
          search: const [
            PipelineStep('template', {
              'value':
                  '<div class="module-items"><div class="module-item">'
                  '<a href="/detail/wrong" title="Wrong">Wrong</a></div></div>'
                  '<section><a href="/detail/right" title="Right">Right</a></section>',
            }),
            PipelineStep.first([
              [
                PipelineStep('searchList', {
                  'selectors': ['.missing'],
                  'detailPattern': '/detail/',
                }),
              ],
              [
                PipelineStep('searchList', {
                  'selectors': ['section'],
                }),
              ],
            ]),
          ],
        ),
        FakeHost({}),
        'query',
      );
      expect(results.map((series) => series.name), ['Right']);
    });

    test('episode parsing deduplicates whole lines and retains line order', () async {
      final sources = await interp.runDetail(
        _pipelineRule(
          detail: const [
            PipelineStep('template', {
              'value':
                  '<nav><b>Line A</b><b>Duplicate</b><b>Line B</b></nav>'
                  '<section><a href="/a1">One</a><a href="/a2">Two</a></section>'
                  '<section><a href="/a1">One</a><a href="/a2">Two</a></section>'
                  '<section><a href="/b1">One</a><a href="/b2">Two</a></section>',
            }),
            PipelineStep('episodes', {
              'listSelectors': ['section'],
              'tabSelectors': ['nav b'],
            }),
          ],
        ),
        FakeHost({}),
        'query',
      );
      expect(sources.map((source) => source.sourceName), ['Line A', 'Line B']);
      expect(sources.last.episodes.map((episode) => episode.episodeId), [
        'https://example.com/b1',
        'https://example.com/b2',
      ]);
    });

    test('HTML readiness does not add an implicit settling delay', () async {
      final host = _WebviewHost(
        expectAsync4((url, isReady, timeout, settleDelay) {
          const html =
              '<script>var player_aaaa={};</script>https://cdn.example.com/ready.mp4';
          expect(settleDelay, Duration.zero);
          expect(isReady!(html), isTrue);
          return html;
        }),
      );
      await interp.runPlay(
        _pipelineRule(
          play: const [
            PipelineStep('sniff', {
              'goal': 'html',
              'url': '/page',
              'readyContains': ['player_aaaa'],
            }),
            PipelineStep('videoUrl', {}),
          ],
        ),
        host,
        '/episode',
      );
    });

    test(
      'torrent search groups releases with ordered fansubs and first cover',
      () async {
        final results = await interp.runSearch(
          _pipelineRule(
            search: const [
              PipelineStep('template', {
                'value':
                    '<ul>'
                    '<li><a href="/a">[A] Series - 01</a></li>'
                    '<li><a href="/b">[B] Series - 02</a><img src="/cover.jpg"></li>'
                    '<li><a href="/c">[A] Series - 03</a><img src="/later.jpg"></li>'
                    '<li><a href="/d">[C] Other - 01</a></li>'
                    '<li><a href="/e">[A] Series - 04 Trailer</a></li>'
                    '</ul>',
              }),
              PipelineStep('torrentRecords', {
                'rowSelector': 'li',
                'titleSelector': 'a',
                'idSelector': 'a',
                'imageSelector': 'img',
                'fansubPattern': r'^\[([^\]]+)\]',
                'animeNamePatterns': [r'\]\s*(.+?)\s+- \d+'],
                'episodePatterns': [r'- (\d+)'],
                'excludePatterns': ['Trailer'],
                'seriesIdTemplate': '/?q={animeName}',
                'descriptionTemplate': '{count:raw} releases {fansubs:raw}',
              }),
            ],
          ),
          FakeHost({}),
          'query',
        );
        expect(results.map((series) => series.name), ['Series', 'Other']);
        expect(results.first.seriesId, 'https://example.com/?q=Series');
        expect(results.first.description, '3 releases A, B');
        expect(results.first.image, 'https://example.com/cover.jpg');
        expect(results.last.description, '1 releases C');
      },
    );

    test('jsonSeries 搜索：fetch → jsonSeries 构建 Series 列表', () async {
      final host = FakeHost({
        'https://example.com/api?wd=%E5%AD%A4%E7%8B%AC':
            '{"list":[{"id":"42","name":"孤独摇滚","pic":"/p.jpg"}]}',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [
          {'op': 'fetch', 'url': '/api?wd={keyword}'},
          {
            'op': 'jsonSeries',
            'listPath': 'list',
            'detailUrlTemplate': '/detail/{id}',
          },
        ],
        'detail': [],
        'play': [],
      });

      final results = await interp.runSearch(rule, host, '孤独');
      expect(results, hasLength(1));
      expect(results.first.name, '孤独摇滚');
      expect(results.first.seriesId, 'https://example.com/detail/42');
      expect(results.first.image, 'https://example.com/p.jpg');
    });

    test('play：follow → first 分支，regex 命中直链', () async {
      final host = FakeHost({
        'https://example.com/play/1':
            'var conf = {"u":"aHR0cHM6Ly9jZG4uZXhhbXBsZS5jb20vdi5tM3U4"};',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [],
        'play': [
          {'op': 'follow', 'url': '{episodeId:raw}'},
          {
            'op': 'first',
            'branches': [
              [
                {'op': 'regex', 'pattern': '"u":"([^"]+)"', 'group': 1},
                {'op': 'crypto', 'algo': 'base64', 'mode': 'decrypt'},
              ],
              [
                {'op': 'videoUrl'},
              ],
            ],
          },
        ],
      });

      final url = await interp.runPlay(rule, host, '/play/1');
      expect(url, 'https://cdn.example.com/v.m3u8');
    });

    test('query + pick + rendered regex choose current episode id', () async {
      final host = FakeHost({
        'https://example.com/video/1600/play?source=1&episode=2':
            'openlistPath:null,sort:0,episodes:[{id:"episodea00000000000001",url:"protected",sort:0}]},'
            'openlistPath:null,sort:0,episodes:[{id:"episodeb00000000000001",url:"protected",sort:0},{id:"episodeb00000000000002",url:"protected",sort:2}]}',
        'https://example.com/api/resolve?episodeId=episodeb00000000000002':
            '{"data":{"url":"https://cdn.example.com/current.m3u8"}}',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [],
        'play': [
          {
            'op': 'query',
            'name': 'source',
            'input': '{episodeId:raw}',
            'default': '0',
            'var': 'sourceIndex',
          },
          {
            'op': 'query',
            'name': 'episode',
            'input': '{episodeId:raw}',
            'default': '0',
            'var': 'episodeSort',
          },
          {'op': 'follow', 'url': '{episodeId:raw}'},
          {
            'op': 'regex',
            'pattern': r'episodes:\[([\s\S]*?)\]\}',
            'group': 1,
            'all': true,
          },
          {'op': 'pick', 'index': '{sourceIndex:raw}'},
          {
            'op': 'regex',
            'pattern':
                'id:"([a-z0-9]{20,})"[^{}]{0,180}url:"protected"[^{}]{0,80}sort[^0-9]{1,24}{episodeSort:raw}\\D',
            'group': 1,
          },
          {'op': 'fetch', 'url': '/api/resolve?episodeId={url}'},
          {'op': 'json', 'path': 'data.url'},
        ],
      });

      final currentUrl = await interp.runPlay(
        rule,
        host,
        '/video/1600/play?source=1&episode=2',
      );
      expect(currentUrl, 'https://cdn.example.com/current.m3u8');
    });

    test('jsonEpisodes：从 JSON 构建播放线路', () async {
      final host = FakeHost({
        'https://example.com/detail/1':
            '{"playlist":[{"id":"a","name":"线路A","eps":[{"vid":"e1","t":"第1集","source_id":"ignored","index":99,"nullable":null},{"vid":"e2","t":"第2集"}]}]}',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [
          {'op': 'follow'},
          {
            'op': 'jsonEpisodes',
            'sourcesPath': 'playlist',
            'episodesKey': 'eps',
            'episodeNameKey': 't',
            'sourceNameKey': 'name',
            'episodeIdTemplate':
                '/watch/{vid}?s={source_id}&line={source_index}&ep={index}&n={nullable}',
          },
        ],
        'play': [],
      });

      final sources = await interp.runDetail(rule, host, '/detail/1');
      expect(sources, hasLength(1));
      expect(sources.first.sourceName, '线路A');
      expect(sources.first.episodes, hasLength(2));
      expect(
        sources.first.episodes.first.episodeId,
        '/watch/e1?s=a&line=0&ep=1&n=',
      );
      expect(
        sources.first.episodes.last.episodeId,
        '/watch/e2?s=a&line=0&ep=2&n=',
      );
      expect(sources.first.episodes[1].name, '第2集');
    });

    test(
      'episodes can reverse a newest-first list and rebuild indexes',
      () async {
        final host = FakeHost(const {
          'https://example.com/detail':
              '<section><a href="/episode/3">第3集</a><a href="/episode/2">第2集</a><a href="/episode/1">第1集</a></section>',
        });
        final rule = SourceRule.fromJson({
          'format': kSourceRuleFormatV2,
          'id': 'reverse-episodes',
          'name': 'Reverse episodes',
          'baseUrl': 'https://example.com',
          'search': [],
          'detail': [
            {'op': 'follow'},
            {
              'op': 'episodes',
              'roadsXPath': '//section',
              'itemsXPath': './/a',
              'reverseEpisodes': true,
            },
          ],
          'play': [],
        });

        final sources = await interp.runDetail(rule, host, '/detail');
        expect(sources.single.episodes.map((episode) => episode.name), [
          '第1集',
          '第2集',
          '第3集',
        ]);
        expect(sources.single.episodes.map((episode) => episode.episode), [
          0,
          1,
          2,
        ]);
      },
    );

    test('jsonEpisodes 的 id 快路径保留变量回退语义', () async {
      final host = FakeHost({
        'https://example.com/detail/1':
            '{"playlist":[{"name":"A","episodes":[{"name":"E"}]}]}',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [
          {'op': 'follow'},
          {'op': 'setVar', 'name': 'id', 'value': 'fallback/id'},
          {'op': 'jsonEpisodes', 'sourcesPath': 'playlist'},
        ],
        'play': [],
      });

      final sources = await interp.runDetail(rule, host, '/detail/1');
      expect(sources.single.episodes.single.episodeId, 'fallback%2Fid');
    });

    test('jsonEpisodes：支持单线路扁平剧集数组', () async {
      final host = FakeHost({
        'https://example.com/api/video/76':
            '{"data":{"episodes":[{"episodeId":61864,"episodeLabel":"第0001集"},{"episodeId":61865,"episodeLabel":"第0002集"}]}}',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [
          {'op': 'follow'},
          {
            'op': 'jsonEpisodes',
            'episodesPath': 'data.episodes',
            'episodeNameKey': 'episodeLabel',
            'episodeIdTemplate': '{episodeId:raw}',
            'sourceName': '青空次元',
          },
        ],
        'play': [],
      });

      final sources = await interp.runDetail(rule, host, '/api/video/76');
      expect(sources, hasLength(1));
      expect(sources.single.sourceName, '青空次元');
      expect(sources.single.episodes, hasLength(2));
      expect(sources.single.episodes.first.episodeId, '61864');
      expect(sources.single.episodes.last.name, '第0002集');
    });

    test('maccmsApiEpisodes：过滤非直连并保留线路与剧集名', () async {
      final host = FakeHost({
        'https://example.com/api.php/provide/vod/?ac=detail&ids=1':
            r'{"list":[{"vod_play_from":"解析线$$$直连线$$$HLS线","vod_play_url":"第1集$opaque-token$$$第1集$https:\/\/cdn.example.com\/1.mp4$$$第2集$https:\/\/cdn.example.com\/2.m3u8"}]}',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [
          {
            'op': 'fetch',
            'url': '/api.php/provide/vod/?ac=detail&ids={seriesId:raw}',
          },
          {'op': 'maccmsApiEpisodes', 'directOnly': true, 'preferHls': true},
        ],
        'play': [
          {'op': 'template', 'value': '{episodeId:raw}'},
        ],
      });

      final sources = await interp.runDetail(rule, host, '1');
      expect(sources, hasLength(2));
      expect(sources.first.sourceName, 'HLS线');
      expect(sources.last.sourceName, '直连线');
      expect(sources.last.episodes, hasLength(1));
      expect(sources.last.episodes.first.name, '第1集');
      expect(
        sources.last.episodes.first.episodeId,
        'https://cdn.example.com/1.mp4',
      );
      expect(sources.first.episodes.single.name, '第2集');
    });

    test('baseN：编码/解码往返一致（fcwdm 短码字母表）', () async {
      const alphabet =
          'CSqxIWYbLFQjsvy9RZdDu0HPait4MTU7NVenrwABXf2GK8EJOhklmp56cg13oz';
      final host = FakeHost(const {});
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [],
        'play': [
          {
            'op': 'baseN',
            'mode': 'encode',
            'alphabet': alphabet,
            'suffix': 'CCS',
          },
          {'op': 'setVar', 'name': 'code', 'value': '{url:raw}'},
          {
            'op': 'baseN',
            'mode': 'decode',
            'alphabet': alphabet,
            'suffix': 'CCS',
            'input': '{code:raw}',
          },
        ],
      });
      final out = await interp.runPlay(rule, host, '123456');
      expect(out, 'https://example.com/123456');
    });

    test('jsonSeries：支持 baseN id 转换生成短码详情页', () async {
      const alphabet =
          'CSqxIWYbLFQjsvy9RZdDu0HPait4MTU7NVenrwABXf2GK8EJOhklmp56cg13oz';
      final host = FakeHost({
        'https://example.com/api?wd=x': '{"list":[{"id":"33930","name":"A"}]}',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [
          {'op': 'fetch', 'url': '/api?wd={keyword}'},
          {
            'op': 'jsonSeries',
            'listPath': 'list',
            'idTransform': 'baseN',
            'idAlphabet': alphabet,
            'idSuffix': 'CCS',
            'detailUrlTemplate': '/bangumi/{id}.html',
          },
        ],
        'detail': [],
        'play': [],
      });

      final results = await interp.runSearch(rule, host, 'x');
      expect(
        results.single.seriesId,
        'https://example.com/bangumi/RlLCCS.html',
      );
    });

    test('ecPlayer：解密 ConFig.url 为直链', () async {
      const direct = 'https://cdn.example.com/video/index.m3u8';
      const uid = 'GFIZ0b';
      const key = '2890${uid}tB959C';
      const iv = '2F131BE91247866E';
      final cipher = encrypt.Encrypter(
        encrypt.AES(
          encrypt.Key.fromUtf8(key),
          mode: encrypt.AESMode.cbc,
          padding: 'PKCS7',
        ),
      ).encrypt(direct, iv: encrypt.IV.fromUtf8(iv)).base64;
      final encoded = jsonEncode({
        'config': {'uid': uid},
        'url': cipher,
      });
      final host = FakeHost({
        'https://example.com/player':
            'let ConFig = $encoded,box = \$("#player");',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [],
        'play': [
          {'op': 'follow'},
          {'op': 'ecPlayer'},
        ],
      });

      final url = await interp.runPlay(rule, host, '/player');
      expect(url, direct);
    });

    test('crypto aes-gcm：base64 密钥 + 随机 IV 加密后可解密回明文', () async {
      final host = FakeHost(const {});
      // 16 字节密钥 "0123456789abcdef" 的 base64。
      const keyB64 = 'MDEyMzQ1Njc4OWFiY2RlZg==';
      const plain = 'https://cdn.example.com/secure/v.m3u8';
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [],
        'play': [
          {
            'op': 'crypto',
            'algo': 'aes-gcm',
            'mode': 'encrypt',
            'key': keyB64,
            'keyEncoding': 'base64',
            'ivRandom': 12,
            'ivVar': 'iv',
          },
          {'op': 'setVar', 'name': 'ct', 'value': '{url:raw}'},
          {
            'op': 'crypto',
            'algo': 'aes-gcm',
            'mode': 'decrypt',
            'key': keyB64,
            'keyEncoding': 'base64',
            'iv': '{iv:raw}',
            'ivEncoding': 'base64',
            'input': '{ct:raw}',
            'inputEncoding': 'base64',
          },
        ],
      });
      final out = await interp.runPlay(rule, host, plain);
      expect(out, plain);
    });

    test(
      'maccmsVerify supports verify_check timestamp xor challenge',
      () async {
        final host = VerifyCheckHost();
        final rule = SourceRule.fromJson({
          'format': kSourceRuleFormatV2,
          'id': 's',
          'name': 'S',
          'baseUrl': 'https://example.com',
          'search': [
            {'op': 'fetch', 'url': '/search/{keyword}'},
            {'op': 'maccmsVerify'},
            {
              'op': 'searchList',
              'selectors': ['li'],
              'detailPattern': '/detail/',
            },
          ],
          'detail': [],
          'play': [],
        });

        final result = await interp.runSearch(rule, host, 'x');
        expect(result.single.name, 'verified');
        expect(host.pageFetches, 2);
        expect(host.verifyMethod, 'POST');
        expect(host.verifyContentType, 'form');

        final body = host.verifyBody as Map;
        final encrypted = base64.decode(body['i'] as String);
        const key = [0x4e, 0x3f, 0xa9, 0xc2];
        final timestamp = utf8.decode(
          List<int>.generate(
            encrypted.length,
            (index) => encrypted[index] ^ key[index % key.length],
          ),
        );
        final millis = int.parse(timestamp);
        expect(
          (DateTime.now().millisecondsSinceEpoch - millis).abs(),
          lessThan(10000),
        );
      },
    );

    test('ALTCHA challenge falls back to ready WebView JSON', () async {
      final host = _WebviewHost(
        expectAsync4((url, isReady, timeout, settleDelay) {
          expect(url, 'https://example.com/suggest');
          expect(
            isReady!('<html><altcha-widget></altcha-widget></html>'),
            isFalse,
          );
          const html =
              '<html><body>{"list":[{"id":30,"name":"鬼灭之刃"}]}</body></html>';
          expect(isReady(html), isTrue);
          return html;
        }),
        responses: const {
          'https://example.com/blocked':
              '<html><altcha-widget></altcha-widget><script src="/aegis_altcha_object/altcha.min.js"></script></html>',
        },
      );
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 'altcha',
        'name': 'ALTCHA',
        'baseUrl': 'https://example.com',
        'search': [
          {
            'op': 'first',
            'branches': [
              [
                {'op': 'fetch', 'url': '/blocked'},
                {'op': 'maccmsVerify'},
              ],
              [
                {
                  'op': 'sniff',
                  'goal': 'html',
                  'url': '/suggest',
                  'readyContains': ['"list"'],
                  'rejectContains': ['altcha-widget', 'aegis_altcha'],
                  'timeoutMs': 30000,
                  'settleMs': 0,
                },
                {'op': 'select', 'css': 'body', 'attr': 'text'},
                {
                  'op': 'jsonSeries',
                  'listPath': 'list',
                  'detailUrlTemplate': '/bangumi/{id}.html',
                },
              ],
            ],
          },
        ],
        'detail': const [],
        'play': const [],
        'useWebview': true,
      });

      final results = await interp.runSearch(rule, host, '鬼灭');

      expect(results, hasLength(1));
      expect(results.single.name, '鬼灭之刃');
      expect(results.single.seriesId, 'https://example.com/bangumi/30.html');
    });

    test('anime1Play 只解析 URL，媒体头与 Cookie 规则交给宿主', () async {
      final host = FakeHost({
        'https://v.anime1.me/api': '{"s":[{"src":"media/video.mp4"}]}',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 'anime1',
        'name': 'Anime1',
        'baseUrl': 'https://anime1.me',
        'search': [],
        'detail': [],
        'play': [
          {
            'op': 'anime1Play',
            'mediaHeaders': {'Referer': 'https://anime1.me/'},
            'cookieNames': ['e'],
            'cookiePrefixes': ['cf_'],
          },
        ],
      });

      final result = await interp.runPlayMedia(rule, host, 'token');
      expect(result.url, 'https://v.anime1.me/media/video.mp4');
      expect(result.mediaHeaders['Referer'], 'https://anime1.me/');
      expect(result.cookieNames, ['e']);
      expect(result.cookiePrefixes, ['cf_']);
    });

    test('first 只提交成功分支，并按实际 sink 输出回退', () async {
      final host = FakeHost(const {});
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [
          {
            'op': 'first',
            'branches': [
              [
                {'op': 'template', 'value': '{"missing":[]}'},
                {'op': 'jsonSeries', 'listPath': 'list'},
              ],
              [
                {
                  'op': 'template',
                  'value': '{"list":[{"id":"1","name":"fallback"}]}',
                },
                {'op': 'jsonSeries', 'listPath': 'list'},
              ],
            ],
          },
        ],
        'detail': [],
        'play': [],
      });

      final result = await interp.runSearch(rule, host, 'x');
      expect(result.single.name, 'fallback');
    });

    test('嵌套 first 只统计最终采用分支实际执行的 sink', () async {
      final host = FakeHost(const {});
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [],
        'play': [
          {
            'op': 'first',
            'branches': [
              [
                {
                  'op': 'first',
                  'branches': [
                    [
                      {'op': 'template', 'value': '{"missing":[]}'},
                      {'op': 'jsonSeries', 'listPath': 'list'},
                    ],
                    [
                      {
                        'op': 'template',
                        'value': 'https://cdn.example.com/nested.mp4',
                      },
                    ],
                  ],
                },
              ],
              [
                {
                  'op': 'template',
                  'value': 'https://cdn.example.com/wrong.mp4',
                },
              ],
            ],
          },
        ],
      });

      expect(
        await interp.runPlay(rule, host, '/unused'),
        'https://cdn.example.com/nested.mp4',
      );
    });

    test('first 失败分支不会泄漏变量或媒体头', () async {
      final host = FakeHost(const {});
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [],
        'detail': [],
        'play': [
          {
            'op': 'first',
            'branches': [
              [
                {'op': 'setVar', 'name': 'leaked', 'value': 'leaked-'},
                {
                  'op': 'setMediaHeaders',
                  'headers': {'X-Leak': 'yes'},
                },
                {'op': 'template', 'value': ''},
              ],
              [
                {
                  'op': 'template',
                  'value': 'https://cdn.example.com/{leaked:raw}video.mp4',
                },
              ],
            ],
          },
        ],
      });

      final media = await interp.runPlayMedia(rule, host, '/unused');
      expect(media.url, 'https://cdn.example.com/video.mp4');
      expect(media.mediaHeaders, isEmpty);
    });

    test('播放结果的媒体元数据不会跨调用残留', () async {
      final host = FakeHost(const {});
      SourceRule ruleWithPlay(List<Map<String, dynamic>> play) =>
          SourceRule.fromJson({
            'format': kSourceRuleFormatV2,
            'id': 's',
            'name': 'S',
            'baseUrl': 'https://example.com',
            'search': [],
            'detail': [],
            'play': play,
          });

      final first = await interp.runPlayMedia(
        ruleWithPlay([
          {
            'op': 'setMediaHeaders',
            'headers': {'Referer': 'https://example.com/'},
          },
          {'op': 'template', 'value': 'https://cdn.example.com/video.mp4'},
        ]),
        host,
        '/first',
      );
      expect(first.mediaHeaders, isNotEmpty);

      final result = await interp.runPlayMedia(
        ruleWithPlay([
          {'op': 'template', 'value': ''},
        ]),
        host,
        '/second',
      );
      expect(result.url, isEmpty);
      expect(result.mediaHeaders, isEmpty);
    });

    test('PipelineStep 支持配方中已构造的嵌套步骤', () async {
      final host = FakeHost({
        'https://example.com/watch':
            'var player_aaaa={"url":"https://cdn.example.com/v.m3u8","encrypt":0};',
      });
      final rule = Recipes.expand(
        SourceRule.fromJson({
          'format': kSourceRuleFormatV2,
          'id': 's',
          'name': 'S',
          'baseUrl': 'https://example.com',
          'recipes': ['player_aaaa'],
          'search': [],
          'detail': [],
          'play': [],
        }),
      );

      final roundTrip = SourceRule.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(rule.toJson())) as Map),
      );
      expect(roundTrip.play[1].branches, hasLength(2));
      expect(
        await interp.runPlay(rule, host, '/watch'),
        'https://cdn.example.com/v.m3u8',
      );
    });

    test('Series 按 id 首次出现去重并保持顺序', () async {
      final host = FakeHost({
        'https://example.com/list':
            '{"list":[{"id":"1","name":"first"},'
            '{"id":"1","name":"duplicate"},'
            '{"id":"2","name":"second"}]}',
      });
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 's',
        'name': 'S',
        'baseUrl': 'https://example.com',
        'search': [
          {'op': 'fetch', 'url': '/list'},
          {'op': 'jsonSeries', 'listPath': 'list'},
        ],
        'detail': [],
        'play': [],
      });

      final result = await interp.runSearch(rule, host, 'x');
      expect(result.map((series) => series.name), ['first', 'second']);
    });

    test('校验器捕获非法正则、退役 op 与非法 baseN', () {
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 'x',
        'name': 'X',
        'baseUrl': 'https://x.com',
        'search': [
          {'op': 'regex', 'pattern': '('},
          {'op': 'bogusOp'},
        ],
        'detail': [],
        'play': [
          {'op': 'baseN', 'alphabet': 'x'},
        ],
      });
      final v = RuleValidator.validate(rule);
      expect(v.isValid, isFalse);
      expect(v.errors.any((e) => e.contains('正则')), isTrue);
      expect(v.errors.any((e) => e.contains('未知 op')), isTrue);
      expect(v.errors.any((e) => e.contains('alphabet')), isTrue);

      expect(
        RuleValidator.validate(
          _rule([
            {'op': 'replace', 'pattern': r'\/', 'replacement': '/'},
            {'op': 'playerDecrypt', 'salt': 'site-salt'},
            {
              'op': 'sniff',
              'goal': 'html',
              'readyRegex': r'player_aaaa|<video',
              'rejectContains': ['DokiDoki CDN'],
            },
          ]),
        ).errors,
        isEmpty,
      );
    });

    test('directConnection is preserved and disables the system proxy', () {
      final rule = SourceRule.fromJson({
        'format': kSourceRuleFormatV2,
        'id': 'direct-source',
        'name': 'Direct source',
        'baseUrl': 'https://example.com',
        'directConnection': true,
        'search': const [],
        'detail': const [],
        'play': const [],
      });

      expect(rule.directConnection, isTrue);
      expect(rule.copyWith().directConnection, isTrue);
      expect(rule.toJson()['directConnection'], isTrue);
      expect(PipelineSourceAdapter(rule).useSystemProxy, isFalse);
    });
  });

  group('player operations', () {
    const interpreter = PipelineInterpreter();

    test('replace normalizes escaped parser URL', () async {
      final result = await interpreter.runPlay(
        _rule([
          {'op': 'template', 'value': r'https:\/\/player.example.com\/parse'},
          {'op': 'replace', 'pattern': r'\/', 'replacement': '/'},
        ]),
        FakeHost(const {}),
        '/unused',
      );

      expect(result, 'https://player.example.com/parse');
    });

    test('playerDecrypt decrypts dynamic meta-id AES-CBC URL', () async {
      const charsetId = '2031';
      const viewportId = 'ABCD';
      const salt = 'test-salt';
      const direct = 'https://cdn.example.com/video.mp4';
      const secret = 'BDAC';
      final hash = md5.convert(utf8.encode('$secret$salt')).toString();
      final cipher = encrypt.Encrypter(
        encrypt.AES(
          encrypt.Key.fromUtf8(hash.substring(16)),
          mode: encrypt.AESMode.cbc,
          padding: 'PKCS7',
        ),
      ).encrypt(direct, iv: encrypt.IV.fromUtf8(hash.substring(0, 16))).base64;
      final html =
          '<meta charset="UTF-8" id="now_$charsetId">'
          '<meta name="viewport" id="now_$viewportId">'
          '<script>var config = {"url":"$cipher"};</script>';
      final host = FakeHost({'https://example.com/player': html});

      for (final decryptStep in <Map<String, dynamic>>[
        {'op': 'playerDecrypt', 'salt': salt},
        {
          'op': 'playerDecrypt',
          'salt': salt,
          'viewportSelector': 'meta[name="viewport"]',
          'charsetSelector': 'meta[charset]',
        },
      ]) {
        final result = await interpreter.runPlay(
          _rule([
            {'op': 'follow'},
            decryptStep,
          ]),
          host,
          '/player',
        );
        expect(result, direct);
      }

      final unquotedHost = FakeHost({
        'https://example.com/player':
            '<meta charset=UTF-8 id=now_$charsetId>'
            '<meta name=viewport id=now_$viewportId>'
            '<script>var config = {"url":"$cipher"};</script>',
      });
      final unquotedResult = await interpreter.runPlay(
        _rule([
          {'op': 'follow'},
          {'op': 'playerDecrypt', 'salt': salt},
        ]),
        unquotedHost,
        '/player',
      );
      expect(unquotedResult, direct);
    });

    test('sniff html forwards rule readiness and timing', () async {
      final host = _WebviewHost(
        expectAsync4((url, isReady, timeout, settleDelay) {
          expect(
            isReady!(
              '<title>DokiDoki CDN</title><script>var player_aaaa={};</script>',
            ),
            isFalse,
          );
          const html =
              '<script>var player_aaaa={};</script>https://cdn.example.com/ready.mp4';
          expect(isReady(html), isTrue);
          expect(timeout, const Duration(seconds: 35));
          expect(settleDelay, const Duration(seconds: 6));
          return html;
        }),
      );
      final result = await interpreter.runPlay(
        _rule([
          {'op': 'template', 'value': 'https://example.com/rendered'},
          {
            'op': 'sniff',
            'goal': 'html',
            'readyRegex': 'player_aaaa',
            'readyIgnoreCase': true,
            'rejectContains': ['DokiDoki CDN'],
            'timeoutMs': 35000,
            'settleMs': 6000,
          },
          {'op': 'videoUrl'},
        ]),
        host,
        '/unused',
      );

      expect(result, 'https://cdn.example.com/ready.mp4');
    });
  });
  group('fallback and cancellation', () {
    const interpreter = PipelineInterpreter();
    test(
      'regex and replace preserve quantifiers alongside raw variables',
      () async {
        final source = _pipelineRule(
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
          'https://example.com/1234',
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
        _pipelineRule(
          play: const [
            PipelineStep('sniff', {
              'goal': 'html',
              'url': '/page',
              'readyRegex': r'^{episodeId:raw}-\d{4}$',
            }),
          ],
        ),
        _WebviewHost(
          expectAsync4((url, isReady, timeout, settleDelay) {
            expect(isReady!('episode-2026'), isTrue);
            expect(isReady('episode-2'), isFalse);
            return 'episode-2026';
          }),
        ),
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
            _pipelineRule(search: const [PipelineStep('maccmsSuggest', {})]),
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
          _pipelineRule(search: const [PipelineStep('maccmsSuggest', {})]),
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
        _pipelineRule(
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
        _pipelineRule(
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
  });
}
