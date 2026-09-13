import 'dart:typed_data';

/// 一路编码的视频指纹：从分片前缀里解出的编码参数。
///
/// 用于判断某个分片是否与清单主体来自同一次编码。拼接进来的广告通常与正片
/// 不是同一次编码，宽高、H.264 level、profile 至少有一项不同。
class HlsVideoFingerprint {
  const HlsVideoFingerprint({
    required this.width,
    required this.height,
    required this.levelIdc,
    required this.profileIdc,
  });

  /// 显示宽度（已扣除 SPS 里的 frame cropping）。
  final int width;

  /// 显示高度（已扣除 SPS 里的 frame cropping）。
  final int height;

  /// H.264 `level_idc`，如 40 = level 4.0、50 = level 5.0。
  final int levelIdc;

  /// H.264 `profile_idc`，如 100 = High。
  final int profileIdc;

  /// 四个参数全等即视为同一次编码。
  bool matches(HlsVideoFingerprint other) =>
      width == other.width &&
      height == other.height &&
      levelIdc == other.levelIdc &&
      profileIdc == other.profileIdc;

  @override
  String toString() => '${width}x$height/L$levelIdc/P$profileIdc';

  @override
  bool operator ==(Object other) =>
      other is HlsVideoFingerprint &&
      other.width == width &&
      other.height == height &&
      other.levelIdc == levelIdc &&
      other.profileIdc == profileIdc;

  @override
  int get hashCode => Object.hash(width, height, levelIdc, profileIdc);
}

/// 从 MPEG-TS 分片前缀里读视频编码参数。
///
/// 只依赖分片开头的少量字节：PAT/PMT 通常在头几个包内，首个 SPS 一般也在
/// 前几 KB。实测 dytt-tvs / jimxtc 的分片里 PMT 在第 376 字节、首个 SPS 起始码
/// 在 601–1375 字节之间，16 KB 前缀足够。fMP4（EXT-X-MAP）不在此实现范围内。
abstract final class MpegTsFingerprint {
  static const int packetSize = 188;
  static const int _syncByte = 0x47;

  /// 视频流类型：H.264。
  static const int _streamTypeH264 = 0x1B;

  /// SPS 的 NAL 单元类型。
  static const int _nalTypeSps = 7;

  /// 使用扩展 `seq_parameter_set_data` 语法的 profile。
  static const Set<int> _extendedProfiles = {
    100,
    110,
    122,
    244,
    44,
    83,
    86,
    118,
    128,
    138,
    139,
    134,
    135,
  };

  /// 解析 [bytes]（分片前缀），失败返回 null。
  static HlsVideoFingerprint? read(Uint8List bytes) {
    if (bytes.length < packetSize * 2) return null;
    final start = _findPacketStart(bytes);
    if (start == null) return null;
    final videoPid = _videoPid(bytes, start);
    if (videoPid == null) return null;
    final sps = _firstNalOfType(bytes, start, videoPid, _nalTypeSps);
    if (sps == null) return null;
    return _parseSps(sps);
  }

  /// 找到连续三个同步字节对齐的位置，避开少数播放器在流前塞入的杂字节。
  static int? _findPacketStart(Uint8List bytes) {
    final limit = bytes.length - packetSize * 3;
    for (var offset = 0; offset <= limit; offset++) {
      if (bytes[offset] != _syncByte) continue;
      if (bytes[offset + packetSize] != _syncByte) continue;
      if (bytes[offset + packetSize * 2] != _syncByte) continue;
      return offset;
    }
    return null;
  }

  /// 该包的净荷；`null` 表示这个包没有净荷。
  static Uint8List? _payload(Uint8List bytes, int offset) {
    final pusi = (bytes[offset + 1] & 0x40) != 0;
    final afc = (bytes[offset + 3] >> 4) & 0x03;
    if (afc == 0 || afc == 2) return null;
    var p = offset + 4;
    if (afc == 3) p += 1 + bytes[offset + 4];
    if (p >= offset + packetSize) return null;
    var payload = Uint8List.sublistView(bytes, p, offset + packetSize);
    if (pusi) {
      final pointer = payload[0];
      final skip = 1 + pointer;
      if (skip >= payload.length) return null;
      payload = Uint8List.sublistView(payload, skip);
    }
    return payload;
  }

  static int _pid(Uint8List bytes, int offset) =>
      ((bytes[offset + 1] & 0x1F) << 8) | bytes[offset + 2];

  /// 取某个 PID 上第一个带净荷的包。
  static Uint8List? _payloadOf(Uint8List bytes, int start, int pid) {
    for (
      var offset = start;
      offset + packetSize <= bytes.length;
      offset += packetSize
    ) {
      if (bytes[offset] != _syncByte) break;
      if (_pid(bytes, offset) != pid) continue;
      final payload = _payload(bytes, offset);
      if (payload != null) return payload;
    }
    return null;
  }

  /// 从 PAT → PMT 找到 H.264 视频流的 PID。
  static int? _videoPid(Uint8List bytes, int start) {
    final pat = _payloadOf(bytes, start, 0);
    if (pat == null || pat.length < 8 || pat[0] != 0x00) return null;
    final sectionLength = ((pat[1] & 0x0F) << 8) | pat[2];
    if (sectionLength < 9) return null;
    final patEnd = 3 + sectionLength - 4;
    int? pmtPid;
    for (var p = 8; p + 4 <= patEnd && p + 4 <= pat.length; p += 4) {
      final program = (pat[p] << 8) | pat[p + 1];
      if (program == 0) continue; // network PID
      pmtPid = ((pat[p + 2] & 0x1F) << 8) | pat[p + 3];
      break;
    }
    if (pmtPid == null) return null;

    final pmt = _payloadOf(bytes, start, pmtPid);
    if (pmt == null || pmt.length < 12 || pmt[0] != 0x02) return null;
    final pmtLength = ((pmt[1] & 0x0F) << 8) | pmt[2];
    if (pmtLength < 13) return null;
    final pmtEnd = 3 + pmtLength - 4;
    var p = 12 + (((pmt[10] & 0x0F) << 8) | pmt[11]);
    while (p + 5 <= pmtEnd && p + 5 <= pmt.length) {
      final streamType = pmt[p];
      final pid = ((pmt[p + 1] & 0x1F) << 8) | pmt[p + 2];
      if (streamType == _streamTypeH264) return pid;
      p += 5 + (((pmt[p + 3] & 0x0F) << 8) | pmt[p + 4]);
    }
    return null;
  }

  /// 拼接该 PID 的净荷并在其中找第一个指定类型的 NAL 单元。
  ///
  /// PES 头（`00 00 01 E0`）不会与 SPS 的起始码混淆，所以无需拆 PES 头。
  static Uint8List? _firstNalOfType(
    Uint8List bytes,
    int start,
    int pid,
    int nalType,
  ) {
    final es = BytesBuilder(copy: false);
    for (
      var offset = start;
      offset + packetSize <= bytes.length;
      offset += packetSize
    ) {
      if (bytes[offset] != _syncByte) break;
      if (_pid(bytes, offset) != pid) continue;
      final payload = _payload(bytes, offset);
      if (payload != null) es.add(payload);
    }
    final data = es.toBytes();
    for (var i = 0; i + 4 < data.length; i++) {
      if (data[i] != 0 || data[i + 1] != 0) continue;
      int header;
      if (data[i + 2] == 1) {
        header = i + 3;
      } else if (data[i + 2] == 0 && data[i + 3] == 1) {
        header = i + 4;
      } else {
        continue;
      }
      if (header >= data.length) continue;
      if ((data[header] & 0x1F) != nalType) continue;
      var end = data.length;
      for (var j = header + 1; j + 3 < data.length; j++) {
        if (data[j] != 0 || data[j + 1] != 0) continue;
        if (data[j + 2] == 1 || (data[j + 2] == 0 && data[j + 3] == 1)) {
          end = j;
          break;
        }
      }
      return Uint8List.sublistView(data, header, end);
    }
    return null;
  }

  /// 去掉防竞争字节（`00 00 03` → `00 00`）。
  static Uint8List _unescape(Uint8List nal) {
    final out = Uint8List(nal.length);
    var n = 0;
    var zeros = 0;
    for (final byte in nal) {
      if (zeros >= 2 && byte == 0x03) {
        zeros = 0;
        continue;
      }
      out[n++] = byte;
      zeros = byte == 0 ? zeros + 1 : 0;
    }
    return Uint8List.sublistView(out, 0, n);
  }

  /// 读 SPS：宽高 + frame cropping + level_idc。
  ///
  /// [nal] 从 NAL 头字节（`0x67`）开始，因此先跳过 1 字节头。
  static HlsVideoFingerprint? _parseSps(Uint8List nal) {
    final reader = _BitReader(_unescape(nal));
    try {
      reader.readBits(8); // NAL 头：forbidden_zero_bit/nal_ref_idc/nal_unit_type
      final profileIdc = reader.readBits(8);
      reader.readBits(8); // constraint flags + reserved bits
      final levelIdc = reader.readBits(8);
      reader.readUnsignedExpGolomb(); // seq_parameter_set_id

      var chromaFormatIdc = 1;
      if (_extendedProfiles.contains(profileIdc)) {
        chromaFormatIdc = reader.readUnsignedExpGolomb();
        if (chromaFormatIdc == 3) reader.readBit(); // separate_colour_plane
        reader.readUnsignedExpGolomb(); // bit_depth_luma_minus8
        reader.readUnsignedExpGolomb(); // bit_depth_chroma_minus8
        reader.readBit(); // qpprime_y_zero_transform_bypass_flag
        if (reader.readBit() == 1) {
          final count = chromaFormatIdc == 3 ? 12 : 8;
          for (var i = 0; i < count; i++) {
            if (reader.readBit() == 1) {
              _skipScalingList(reader, i < 6 ? 16 : 64);
            }
          }
        }
      }

      reader.readUnsignedExpGolomb(); // log2_max_frame_num_minus4
      final pocType = reader.readUnsignedExpGolomb();
      if (pocType == 0) {
        reader.readUnsignedExpGolomb(); // log2_max_pic_order_cnt_lsb_minus4
      } else if (pocType == 1) {
        reader.readBit(); // delta_pic_order_always_zero_flag
        reader.readSignedExpGolomb();
        reader.readSignedExpGolomb();
        final cycle = reader.readUnsignedExpGolomb();
        for (var i = 0; i < cycle; i++) {
          reader.readSignedExpGolomb();
        }
      }

      reader.readUnsignedExpGolomb(); // max_num_ref_frames
      reader.readBit(); // gaps_in_frame_num_value_allowed_flag
      final widthInMbs = reader.readUnsignedExpGolomb() + 1;
      final heightInMapUnits = reader.readUnsignedExpGolomb() + 1;
      final frameMbsOnly = reader.readBit();
      if (frameMbsOnly == 0) reader.readBit(); // mb_adaptive_frame_field_flag
      reader.readBit(); // direct_8x8_inference_flag

      var cropLeft = 0;
      var cropRight = 0;
      var cropTop = 0;
      var cropBottom = 0;
      if (reader.readBit() == 1) {
        cropLeft = reader.readUnsignedExpGolomb();
        cropRight = reader.readUnsignedExpGolomb();
        cropTop = reader.readUnsignedExpGolomb();
        cropBottom = reader.readUnsignedExpGolomb();
      }

      final subWidthC = chromaFormatIdc == 1 || chromaFormatIdc == 2 ? 2 : 1;
      final subHeightC = chromaFormatIdc == 1 ? 2 : 1;
      final cropUnitX = subWidthC;
      final cropUnitY = subHeightC * (2 - frameMbsOnly);
      final width =
          widthInMbs * 16 - cropUnitX * (cropLeft + cropRight);
      final height =
          (2 - frameMbsOnly) * heightInMapUnits * 16 -
          cropUnitY * (cropTop + cropBottom);
      if (width <= 0 || height <= 0) return null;
      return HlsVideoFingerprint(
        width: width,
        height: height,
        levelIdc: levelIdc,
        profileIdc: profileIdc,
      );
    } catch (_) {
      return null;
    }
  }

  /// `scaling_list()`：只关心长度，读完即弃。
  static void _skipScalingList(_BitReader reader, int size) {
    var lastScale = 8;
    var nextScale = 8;
    for (var i = 0; i < size; i++) {
      if (nextScale != 0) {
        final delta = reader.readSignedExpGolomb();
        nextScale = (lastScale + delta + 256) % 256;
      }
      lastScale = nextScale == 0 ? lastScale : nextScale;
    }
  }
}

class _BitReader {
  _BitReader(this._data);

  final Uint8List _data;
  int _bitOffset = 0;

  int readBit() {
    if (_bitOffset >= _data.length * 8) {
      throw StateError('bit reader overflow');
    }
    final byte = _data[_bitOffset >> 3];
    final bit = (byte >> (7 - (_bitOffset & 7))) & 0x01;
    _bitOffset++;
    return bit;
  }

  int readBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 1) | readBit();
    }
    return value;
  }

  int readUnsignedExpGolomb() {
    var zeros = 0;
    while (readBit() == 0) {
      zeros++;
      if (zeros > 31) throw StateError('invalid exp golomb');
    }
    if (zeros == 0) return 0;
    return (1 << zeros) - 1 + readBits(zeros);
  }

  int readSignedExpGolomb() {
    final value = readUnsignedExpGolomb();
    return (value & 1) == 1 ? (value + 1) >> 1 : -(value >> 1);
  }
}
