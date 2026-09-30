import 'dart:convert';
import 'dart:io';

import 'package:baka/source/hls/hls_manifest_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

const _animoeDecoder = <String, dynamic>{
  'scheme': 'xor',
  'prefix': 'enc',
  'key': [144, 223, 214, 167, 22, 76, 53],
  'period': 10,
  'fallbackIndex': 6,
  'xor': 165,
  'skipBytes': 3,
  'trimPrefixBeforeM3u8': true,
};

void main() {
  test(
    'decodes a captured Animoe binary playlist prefix without mutating it',
    () {
      final bytes = File(
        'test/fixtures/hls/animoe_manifest_prefix.bin',
      ).readAsBytesSync();
      final original = List<int>.from(bytes);
      final expected = File(
        'test/fixtures/hls/animoe_manifest_prefix.txt',
      ).readAsStringSync();
      expect(HlsManifestDecoder.decode(bytes, _animoeDecoder), expected);
      expect(expected, startsWith('#EXTM3U\n#EXT-X-VERSION:7'));
      expect(expected, contains('#EXT-X-MAP:URI="https://nos.netease.com/'));
      expect(bytes, original);
    },
  );

  test('accepts plain HLS and leaves unknown prefixes unchanged', () {
    const plain = '#EXTM3U\n#EXT-X-ENDLIST\n';
    expect(
      HlsManifestDecoder.decode(utf8.encode(plain), _animoeDecoder),
      plain,
    );
    expect(
      HlsManifestDecoder.decode(utf8.encode('other body'), _animoeDecoder),
      'other body',
    );
  });

  test('rejects truncated, corrupt and unsupported binary decoding', () {
    for (final bytes in [
      [101, 110, 99],
      [101, 110, 99, 0, 0, 0, 0],
    ]) {
      expect(
        () => HlsManifestDecoder.decode(bytes, _animoeDecoder),
        throwsFormatException,
      );
    }
    for (final override in <Map<String, dynamic>>[
      {'scheme': 'unknown'},
      {'key': []},
      {'period': 0},
      {'fallbackIndex': 7},
      {'xor': 256},
      {'skipBytes': 2},
    ]) {
      expect(
        () => HlsManifestDecoder.decode(
          [101, 110, 99, 1],
          {..._animoeDecoder, ...override},
        ),
        throwsFormatException,
      );
    }
  });
}
