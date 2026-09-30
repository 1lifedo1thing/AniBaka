import 'dart:convert';

/// Decodes a rule-declared binary playlist without executing site scripts.
class HlsManifestDecoder {
  HlsManifestDecoder._();

  static String decode(List<int> bytes, Map<String, dynamic> declaration) {
    if (declaration['scheme'] != 'xor') {
      throw const FormatException('unsupported HLS manifest decoder');
    }
    final prefix = declaration['prefix'];
    final rawKey = declaration['key'];
    final period = declaration['period'];
    final fallbackIndex = declaration['fallbackIndex'];
    final xor = declaration['xor'];
    final skipBytes = declaration['skipBytes'];
    if (prefix is! String ||
        prefix.isEmpty ||
        rawKey is! List ||
        rawKey.isEmpty ||
        rawKey.any((value) => value is! int || value < 0 || value > 255) ||
        period is! int ||
        period <= 0 ||
        fallbackIndex is! int ||
        fallbackIndex < 0 ||
        fallbackIndex >= rawKey.length ||
        xor is! int ||
        xor < 0 ||
        xor > 255 ||
        skipBytes is! int ||
        skipBytes < utf8.encode(prefix).length) {
      throw const FormatException('invalid HLS manifest decoder parameters');
    }

    final prefixBytes = utf8.encode(prefix);
    var matchesPrefix = bytes.length >= prefixBytes.length;
    for (var index = 0; matchesPrefix && index < prefixBytes.length; index++) {
      matchesPrefix = bytes[index] == prefixBytes[index];
    }
    // Plain playlists remain valid when a site changes a line back to normal HLS.
    // Unknown or corrupt responses are left for the playlist validation to reject.
    if (!matchesPrefix) return utf8.decode(bytes);
    if (bytes.length <= skipBytes) {
      throw const FormatException('truncated encrypted HLS manifest');
    }

    final key = rawKey.cast<int>();
    final decoded = <int>[];
    for (var index = skipBytes; index < bytes.length; index++) {
      final position = index % period;
      decoded.add(
        bytes[index] ^
            key[position < key.length ? position : fallbackIndex] ^
            xor,
      );
    }
    var manifest = utf8.decode(decoded);
    if (declaration['trimPrefixBeforeM3u8'] == true) {
      final start = manifest.indexOf('#EXTM3U');
      if (start > 0) manifest = manifest.substring(start);
    }
    if (!manifest.startsWith('#EXTM3U')) {
      throw const FormatException('invalid decoded HLS manifest');
    }
    return manifest;
  }
}
