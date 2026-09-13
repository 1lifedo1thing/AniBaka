import 'package:baka/source/hls/hls_master_playlist.dart';
import 'package:flutter_test/flutter_test.dart';

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
  test('主清单与媒体清单可区分', () {
    expect(HlsMasterPlaylist.isMaster(_singleVariant), isTrue);
    expect(HlsMasterPlaylist.isMaster(_multiVariant), isTrue);
    expect(HlsMasterPlaylist.isMaster(_mediaPlaylist), isFalse);
  });

  test('解析变体：地址按主清单地址解析，属性缺失不致命', () {
    final variants = HlsMasterPlaylist.variants(_multiVariant, _baseUri);

    // I-FRAME 变体不算在内。
    expect(variants, hasLength(3));
    expect(
      variants.map((variant) => variant.uri.toString()),
      [
        'https://vip.example/20260906/35899/360p/index.m3u8',
        'https://vip.example/20260906/35899/1080p/index.m3u8',
        'https://vip.example/20260906/35899/540p/index.m3u8',
      ],
    );
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
    final selected = HlsMasterPlaylist.selectVariant(_singleVariant, _baseUri);

    expect(selected!.uri.toString(), endsWith('3000k/hls/mixed.m3u8'));
  });

  test('带独立音轨的清单不接管，返回 null', () {
    expect(HlsMasterPlaylist.hasAlternativeRenditions(_withAudioRendition), isTrue);
    expect(
      HlsMasterPlaylist.selectVariant(_withAudioRendition, _baseUri),
      isNull,
    );
  });

  test('没有变体时返回 null', () {
    expect(HlsMasterPlaylist.selectVariant(_mediaPlaylist, _baseUri), isNull);
  });
}
