import 'dart:convert';
import 'dart:typed_data';

import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ts_prefix_fixtures.dart';

void main() {
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
}
