import 'dart:math' as math;
import 'dart:typed_data';

import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';

/// Streams MPEG-TS after removing a bounded image/junk prefix when requested by
/// a rule. Unknown bodies pass through unchanged; whole segments are not buffered.
abstract final class HlsTsPrefix {
  static const probeBytes = 16 * 1024;

  static Stream<Uint8List> strip(
    Stream<Uint8List> source, {
    required void Function(int removedBytes) onTransportStream,
  }) async* {
    final pending = BytesBuilder(copy: false);
    var probing = true;
    await for (final chunk in source) {
      if (!probing) {
        yield chunk;
        continue;
      }
      pending.add(chunk);
      if (pending.length < MpegTsFingerprint.packetSize * 3) continue;
      final bytes = pending.takeBytes();
      final start = MpegTsFingerprint.findPacketStart(
        Uint8List.sublistView(bytes, 0, math.min(bytes.length, probeBytes)),
      );
      if (start == null && bytes.length < probeBytes) {
        pending.add(bytes);
        continue;
      }
      probing = false;
      if (start != null) onTransportStream(start);
      yield start == null ? bytes : Uint8List.sublistView(bytes, start);
    }
    if (pending.isNotEmpty) yield pending.takeBytes();
  }
}
