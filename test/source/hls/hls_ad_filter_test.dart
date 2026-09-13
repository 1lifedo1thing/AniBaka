import 'package:baka/source/hls/hls_ad_filter.dart';
import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';

/// 正片指纹：1920x816、level 4.0、High profile。
const _content = HlsVideoFingerprint(
  width: 1920,
  height: 816,
  levelIdc: 40,
  profileIdc: 100,
);

/// 广告指纹：1920x1080、level 5.0、High profile（实测样本）。
const _ad = HlsVideoFingerprint(
  width: 1920,
  height: 1080,
  levelIdc: 50,
  profileIdc: 100,
);

final _manifestUri = Uri.parse('https://cdn.example/hls/index.m3u8');

/// 每个块是一个 `#EXT-X-DISCONTINUITY` 分组；块内每个名字生成一个 4 秒分片，
/// 分片名带指纹前缀，探测函数据此前缀返回指纹。
String _build(List<List<String>> blocks) {
  final lines = <String>[
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-TARGETDURATION:8',
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:VOD',
  ];
  var index = 0;
  for (final names in blocks) {
    lines.add('#EXT-X-DISCONTINUITY');
    for (final name in names) {
      lines.add('#EXTINF:4.000,');
      lines.add('${name}_$index.ts');
      index++;
    }
  }
  lines.add('#EXT-X-ENDLIST');
  return lines.join('\n');
}

List<String> _contentBlock([int count = 5]) =>
    List<String>.filled(count, 'content');

List<String> _adBlock(int count) => List<String>.filled(count, 'ad');

/// 分片名前缀决定指纹；[nullFor] 里的分片模拟探测失败。
Future<HlsVideoFingerprint?> Function(Uri) _probe({
  Set<String> nullFor = const {},
}) {
  return (uri) async {
    final name = uri.pathSegments.last;
    if (nullFor.contains(name)) return null;
    if (name.startsWith('content')) return _content;
    if (name.startsWith('ad')) return _ad;
    return null;
  };
}

int _segmentsOf(String manifest) =>
    manifest.split('\n').where((line) => line.endsWith('.ts')).length;

int _discontinuitiesOf(String manifest) => manifest
    .split('\n')
    .where((line) => line.trim() == '#EXT-X-DISCONTINUITY')
    .length;

void main() {
  test('删除整组异编码分片，保留其余分片与清单结构', () async {
    final manifest = _build([
      _contentBlock(),
      _contentBlock(),
      _adBlock(3), // 广告段：正片 100s / 广告 12s
      _contentBlock(),
      _contentBlock(),
      _contentBlock(),
    ]);
    expect(_segmentsOf(manifest), 28);
    expect(_discontinuitiesOf(manifest), 6);

    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: _probe(),
    );

    expect(outcome.changed, isTrue);
    expect(outcome.removedSegments, 3);
    expect(outcome.removedSeconds, closeTo(12, 1e-9));
    expect(outcome.detail, contains('1920x816/L40/P100'));
    expect(outcome.manifest, isNot(contains('ad_')));
    expect(_segmentsOf(outcome.manifest), 25);
    // 广告组的 discontinuity 标记随整组一起删除，不留空标记。
    expect(_discontinuitiesOf(outcome.manifest), 5);
    expect(outcome.manifest, startsWith('#EXTM3U'));
    expect(outcome.manifest, contains('#EXT-X-ENDLIST'));

    // 剩余的 EXTINF 与 URI 仍一一对应。
    final lines = outcome.manifest.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXTINF:')) continue;
      expect(lines[i + 1].endsWith('.ts'), isTrue);
    }
  });

  test('全部指纹一致时原样返回，不复制清单', () async {
    final manifest = _build([_contentBlock(), _contentBlock(), _contentBlock()]);

    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: _probe(),
    );

    expect(outcome.changed, isFalse);
    expect(identical(outcome.manifest, manifest), isTrue);
    expect(outcome.detail, contains('未发现异编码片段'));
  });

  test('连续异编码片段超过 60s 上限时放弃过滤', () async {
    // 20 片 x 4s = 80s 的连续异编码片段，更像多段不同编码的正片而不是广告。
    final manifest = _build([
      ...List.generate(6, (_) => _contentBlock()),
      _adBlock(20),
      ...List.generate(6, (_) => _contentBlock()),
    ]);

    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: _probe(),
    );

    expect(outcome.changed, isFalse);
    expect(identical(outcome.manifest, manifest), isTrue);
    expect(outcome.detail, contains('超过 60s 上限'));
  });

  test('异编码片段占多数时不会反过来把正片当广告删掉', () async {
    // 广告 80s 比正片 40s 还长：多数票会落在“广告”指纹上，占比上限兜住。
    final manifest = _build([_adBlock(20), _contentBlock(5), _contentBlock(5)]);

    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: _probe(),
    );

    expect(outcome.changed, isFalse);
    expect(identical(outcome.manifest, manifest), isTrue);
    expect(outcome.manifest, contains('content_20.ts'));
    expect(outcome.detail, contains('15% 上限'));
  });

  test('删除总量超过整条清单 15% 时放弃过滤', () async {
    // 正片 24s / 广告 12s = 33%，超过占比上限。
    final manifest = _build([_contentBlock(3), _adBlock(3), _contentBlock(3)]);

    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: _probe(),
    );

    expect(outcome.changed, isFalse);
    expect(identical(outcome.manifest, manifest), isTrue);
    expect(outcome.detail, contains('15% 上限'));
  });

  test('探测失败的分片按正片保留', () async {
    final manifest = _build([
      _contentBlock(),
      _contentBlock(),
      _adBlock(3),
      _contentBlock(),
      _contentBlock(),
    ]);

    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: _probe(nullFor: {'ad_11.ts'}),
    );

    expect(outcome.changed, isTrue);
    expect(outcome.removedSegments, 2);
    expect(outcome.manifest, contains('ad_11.ts'));
    expect(outcome.manifest, isNot(contains('ad_10.ts')));
    expect(outcome.manifest, isNot(contains('ad_12.ts')));
  });

  test('组首片与主体一致时不再深入该组（已知局限）', () async {
    // 广告只占组内后两片，组首仍是正片：本实现只看组首，不会发现。
    final manifest = _build([
      _contentBlock(),
      _contentBlock(),
      const ['content', 'content', 'content', 'ad', 'ad'],
      _contentBlock(),
    ]);

    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: _probe(),
    );

    expect(outcome.changed, isFalse);
    expect(identical(outcome.manifest, manifest), isTrue);
  });

  test('分片太少时不做任何探测', () async {
    final manifest = _build([_contentBlock(2)]);
    var probes = 0;

    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: (uri) async {
        probes++;
        return _content;
      },
    );

    expect(probes, 0);
    expect(outcome.changed, isFalse);
  });

  test('清单级标签与 #EXT-X-KEY 不会被连带删除', () async {
    final manifest = _build([
      _adBlock(3),
      _contentBlock(),
      _contentBlock(),
      _contentBlock(),
      _contentBlock(),
      _contentBlock(),
    ]).replaceFirst(
      '#EXT-X-DISCONTINUITY\n#EXTINF:4.000,\nad_0.ts',
      '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXT-X-DISCONTINUITY\n#EXTINF:4.000,\nad_0.ts',
    );

    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: _probe(),
    );

    expect(outcome.changed, isTrue);
    expect(outcome.manifest, contains('#EXT-X-KEY:METHOD=AES-128'));
    expect(outcome.manifest, contains('#EXT-X-TARGETDURATION:8'));
    expect(outcome.manifest, isNot(contains('ad_')));
  });
}
