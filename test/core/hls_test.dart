import 'dart:convert';
import 'dart:typed_data';
import 'package:baka/source/hls/hls_ad_filter.dart';
import 'package:baka/source/hls/hls_master_playlist.dart';
import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/ts_prefix_fixtures.dart';

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

/// 本次实测的 dytt-tvs 主清单：单码率变体。原文见
/// `docs/research/hls_instream_ads_20260912.md`。
const _singleVariant = '''
#EXTM3U
#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=800000,RESOLUTION=1920x816
3000k/hls/mixed.m3u8
''';

const _multiVariant = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=640x360
360p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x816
1080p/index.m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=99000,URI="iframes/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=900000
540p/index.m3u8
''';

const _withAudioRendition = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="国语",URI="audio/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aac",RESOLUTION=1920x816
video/index.m3u8
''';

const _mediaPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:8
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.000,
seg0.ts
#EXT-X-ENDLIST
''';

final _baseUri = Uri.parse('https://vip.example/20260906/35899/index.m3u8');

void main() {
  group('ad filtering', () {
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
      final manifest = _build([
        _contentBlock(),
        _contentBlock(),
        _contentBlock(),
      ]);

      final outcome = await HlsAdFilter.apply(
        manifest: manifest,
        manifestUri: _manifestUri,
        probe: _probe(),
      );

      expect(outcome.changed, isFalse);
      expect(outcome.manifest, manifest);
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
      expect(outcome.manifest, manifest);
      expect(outcome.detail, contains('超过 60s 上限'));
    });

    test('异编码片段占多数时不会反过来把正片当广告删掉', () async {
      // 广告 80s 比正片 40s 还长：多数票会落在“广告”指纹上，占比上限兜住。
      final manifest = _build([
        _adBlock(20),
        _contentBlock(5),
        _contentBlock(5),
      ]);

      final outcome = await HlsAdFilter.apply(
        manifest: manifest,
        manifestUri: _manifestUri,
        probe: _probe(),
      );

      expect(outcome.changed, isFalse);
      expect(outcome.manifest, manifest);
      expect(outcome.manifest, contains('content_20.ts'));
      expect(outcome.detail, contains('15% 上限'));
    });

    test('删除总量超过整条清单 15% 时放弃过滤', () async {
      // 正片 24s / 广告 12s = 33%，超过占比上限。
      final manifest = _build([
        _contentBlock(3),
        _adBlock(3),
        _contentBlock(3),
      ]);

      final outcome = await HlsAdFilter.apply(
        manifest: manifest,
        manifestUri: _manifestUri,
        probe: _probe(),
      );

      expect(outcome.changed, isFalse);
      expect(outcome.manifest, manifest);
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
      expect(
        outcome.manifest,
        contains('#EXT-X-DISCONTINUITY\n#EXTINF:4.000,\nad_11.ts'),
      );
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

    test('加密清单原文保留，不做不安全的分片删除', () async {
      final manifest =
          _build([
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

      expect(outcome.changed, isFalse);
      expect(outcome.manifest, manifest);
      expect(outcome.manifest, contains('#EXT-X-KEY:METHOD=AES-128'));
      expect(outcome.manifest, contains('#EXT-X-TARGETDURATION:8'));
      expect(outcome.manifest, contains('ad_'));
    });
  });

  for (final tag in [
    '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"',
    '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x01',
    '#EXT-X-MAP:URI="init.mp4"',
    '#EXT-X-BYTERANGE:100',
    '#EXT-X-BYTERANGE:100@200',
  ]) {
    for (final afterBoundary in [false, true]) {
      test(
        'complex HLS is unchanged with zero probes: $tag after=$afterBoundary',
        () async {
          final original = _build([
            _contentBlock(),
            _adBlock(1),
            _contentBlock(),
          ]);
          final manifest = original.replaceFirst(
            '#EXT-X-DISCONTINUITY',
            afterBoundary
                ? '#EXT-X-DISCONTINUITY\n$tag'
                : '$tag\n#EXT-X-DISCONTINUITY',
          );
          var probes = 0;
          final outcome = await HlsAdFilter.apply(
            manifest: manifest,
            manifestUri: _manifestUri,
            probe: (_) async {
              probes++;
              return _content;
            },
          );
          expect(outcome.manifest, manifest);
          expect(probes, 0);
        },
      );
    }
  }
  test('DISCONTINUITY-SEQUENCE survives removing the first group', () async {
    final manifest = _build([
      _adBlock(1),
      _contentBlock(),
      _contentBlock(),
      _contentBlock(),
    ]).replaceFirst('#EXTM3U', '#EXTM3U\n#EXT-X-DISCONTINUITY-SEQUENCE:8');
    final outcome = await HlsAdFilter.apply(
      manifest: manifest,
      manifestUri: _manifestUri,
      probe: _probe(),
    );
    expect(outcome.changed, isTrue);
    expect(outcome.manifest, contains('#EXT-X-DISCONTINUITY-SEQUENCE:8'));
  });

  group('master playlists', () {
    test('主清单与媒体清单可区分', () {
      expect(HlsMasterPlaylist.isMaster(_singleVariant), isTrue);
      expect(HlsMasterPlaylist.isMaster(_multiVariant), isTrue);
      expect(HlsMasterPlaylist.isMaster(_mediaPlaylist), isFalse);
    });

    test('解析变体：地址按主清单地址解析，属性缺失不致命', () {
      final variants = HlsMasterPlaylist.variants(_multiVariant, _baseUri);

      // I-FRAME 变体不算在内。
      expect(variants, hasLength(3));
      expect(variants.map((variant) => variant.uri.toString()), [
        'https://vip.example/20260906/35899/360p/index.m3u8',
        'https://vip.example/20260906/35899/1080p/index.m3u8',
        'https://vip.example/20260906/35899/540p/index.m3u8',
      ]);
      expect(variants[0].bandwidth, 400000);
      expect(variants[0].resolution, '640x360');
      expect(variants[2].resolution, isNull);
      expect(variants[2].bandwidth, 900000);
    });

    test('选定变体取最高 BANDWIDTH', () {
      final selected = HlsMasterPlaylist.selectVariant(_multiVariant, _baseUri);

      expect(selected, isNotNull);
      expect(selected!.uri.toString(), endsWith('1080p/index.m3u8'));
      expect(selected.label, '1920x816@2000kbps');
    });

    test('单变体主清单也能选定', () {
      final selected = HlsMasterPlaylist.selectVariant(
        _singleVariant,
        _baseUri,
      );

      expect(selected!.uri.toString(), endsWith('3000k/hls/mixed.m3u8'));
    });

    test('带独立音轨的清单不接管，返回 null', () {
      expect(
        HlsMasterPlaylist.hasAlternativeRenditions(_withAudioRendition),
        isTrue,
      );
      expect(
        HlsMasterPlaylist.selectVariant(_withAudioRendition, _baseUri),
        isNull,
      );
    });

    test('没有变体时返回 null', () {
      expect(HlsMasterPlaylist.selectVariant(_mediaPlaylist, _baseUri), isNull);
    });
  });

  group('TS fingerprints', () {
    test('正片前缀读出 1920x816 / level 4.0 / High profile', () {
      final fingerprint = MpegTsFingerprint.read(contentPrefixBytes);

      expect(fingerprint, isNotNull);
      expect(fingerprint!.width, 1920);
      expect(fingerprint.height, 816);
      expect(fingerprint.levelIdc, 40);
      expect(fingerprint.profileIdc, 100);
      expect(fingerprint.toString(), '1920x816/L40/P100');
    });

    test('广告前缀读出 1920x1080 / level 5.0（已扣除 frame cropping）', () {
      final fingerprint = MpegTsFingerprint.read(adPrefixBytes);

      expect(fingerprint, isNotNull);
      expect(fingerprint!.width, 1920);
      // SPS 编码高度 1088 行，crop_bottom_offset=4、crop_unit_y=2，显示高度 1080。
      expect(fingerprint.height, 1080);
      expect(fingerprint.levelIdc, 50);
      expect(fingerprint.profileIdc, 100);
    });

    test('正片与广告互不匹配', () {
      final content = MpegTsFingerprint.read(contentPrefixBytes);
      final ad = MpegTsFingerprint.read(adPrefixBytes);

      expect(content!.matches(ad!), isFalse);
      expect(content.matches(content), isTrue);
      expect(content, isNot(equals(ad)));
    });

    test('前缀被截断、非 TS 内容或空输入都返回 null', () {
      expect(MpegTsFingerprint.read(Uint8List(0)), isNull);
      expect(
        MpegTsFingerprint.read(Uint8List.fromList(List<int>.filled(4096, 0))),
        isNull,
      );
      expect(
        MpegTsFingerprint.read(Uint8List.fromList(utf8.encode('plain text'))),
        isNull,
      );
      // 512 字节还读不到 SPS，应放弃而不是猜。
      expect(
        MpegTsFingerprint.read(
          Uint8List.sublistView(contentPrefixBytes, 0, 512),
        ),
        isNull,
      );
    });
  });
}
