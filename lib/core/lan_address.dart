import 'dart:io';

final class LanAddress {
  LanAddress._();

  static Future<InternetAddress?> findIpv4() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    InternetAddress? first;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback || address.isLinkLocal) continue;
        first ??= address;
        if (_isPrivate(address.address)) return address;
      }
    }
    return first;
  }

  static bool _isPrivate(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return false;
    final first = int.tryParse(parts[0]);
    final second = int.tryParse(parts[1]);
    return first == 10 ||
        (first == 172 && second != null && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }
}
