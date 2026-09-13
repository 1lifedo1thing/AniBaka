import 'dart:convert';
import 'dart:typed_data';

/// 真实样本：`vip.dytt-tvs.com/20260906/35899_5c964f28/index.m3u8` 对应的媒体
/// 清单里，正片第 1 个分片（gi=0/si=0）的前 1536 字节。
///
/// 取自线上响应，未做任何本地转码。ffprobe 报告 1920x816 / level 4.0 / 25fps。
const String contentPrefixBase64 =
    'R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////'
    '////////////////////////////////////////////////////////////////////////////////////////////////'
    '//////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////'
    '////////////////////////////////////////////////////////////////////////////////////////////////'
    '////////////////////////////////////////////////////////////////////////////////////////////////'
    '/////////////////////0dQABAAArAdAAHBAADhAPAAG+EA8AAP4QHwBgoEdW5kAAh96Hf/////////////////////////'
    '////////////////////////////////////////////////////////////////////////////////////////////////'
    '////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4A'
    'AAAB4AAAgMAKMQAJEKERAAfYYQAAAAEJ8AAAAAEGBf//7txF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjQgcjMxOTEg'
    'NDYxM2FjMyAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjQgLSBodHRwOi8vd3d3LnZpZGVv'
    'bGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJHAQARYWM9MSByZWY9MSBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgz'
    'OjB4MTEzIG1lPWhleCBzdWJtZT0yIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hy'
    'b21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBf'
    'b2Zmc0cBABJldD0wIHRocmVhZHM9MjUgbG9va2FoZWFkX3RocmVhZHM9NiBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1h'
    'dGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1p'
    'ZD0yIGJfYWRhcHQ9MSBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTEgb3Blbl9nRwEAE29wPTAgd2VpZ2h0cD0xIGtleWlu'
    'dD0xMDAga2V5aW50X21pbj0xMCBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTEwIHJjPWNyZiBt'
    'YnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgdmJ2X21heHJhdGU9MzAwMCB2'
    'YnZfYnVmc2l6ZT02MDAwIGNyZl9HAQAUbWF4PTAuMCBuYWxfaHJkPW5vbmUgZmlsbGVyPTAgaXBfcmF0aW89MS40MCBhcT0x'
    'OjEuMDAAgAAAAAFnZAAorNlAeAZ7AWoCAgKAAAADAIAAABkHjBjLAAAAAWjvj8sAAAFliIQAf7VAa59M7mjNWgfpl+9Q8ePo'
    'c74zjlwIxnS/6zyA4AAAAwAAAwAAAwAAAwAAAwBsH+a8ogaopS0iiwo77JMjkAAAAwAAAwAAf4AAADWAAAAfAEcBABUAAwAV'
    'YAAAFGAAABTAAAAegAAAJIAAAEEAAAMA';

/// 同一清单里被拼接进来的广告段（gi=16/si=0）的前 1536 字节。
///
/// ffprobe 报告 1920x1080 / level 5.0 / 30fps / AAC 44.1kHz，与正片不是同一次编码。
const String adPrefixBase64 =
    'R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////'
    '////////////////////////////////////////////////////////////////////////////////////////////////'
    '//////////////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////'
    '////////////////////////////////////////////////////////////////////////////////////////////////'
    '////////////////////////////////////////////////////////////////////////////////////////////////'
    '/////////////////////0dQABAAArAdAAHBAADhAPAAG+EA8AAP4QHwBgoEdW5kAAh96Hf/////////////////////////'
    '////////////////////////////////////////////////////////////////////////////////////////////////'
    '////////////////////////////////////////////////////////////////////////////////R0EAMAdQAAB7DH4A'
    'AAAB4AAAgMAKMQAJB0ERAAfYYQAAAAEJ8AAAAAFnZAAyrNmAeAIn5ZqAgICgAAADACAAAAeB4wYzQAAAAAFo6XjyyLAAAAEG'
    'Bf//79xF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjQgcjMxOTEgNDYxM2FjMyAtIEguMjY0L01QRUctNCBBVkMgY29k'
    'ZWMgLSBDb3B5bGVmdCAyMDAzLTIwMjQgLSBodHRwOi9HAQARL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9u'
    'czogY2FiYWM9MSByZWY9NSBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT04IHBzeT0xIHBz'
    'eV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0yIDh4OGRjdD0xIGNx'
    'bT0wIEcBABJkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTM0IGxvb2th'
    'aGVhZF90aHJlYWRzPTUgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21w'
    'YXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MyBiX3B5cmFtaWQ9MiBiRwEAE19hZGFwdD0xIGJfYmlhcz0wIGRp'
    'cmVjdD0zIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MTAwIGtleWludF9taW49MTAgc2NlbmVjdXQ9'
    'NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD01MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBx'
    'cG1pbj0wIHFwbWF4PTY5IHFwc3RHAQAUZXA9NCB2YnZfbWF4cmF0ZT0zMDAwIHZidl9idWZzaXplPTI0MDAgY3JmX21heD0w'
    'LjAgbmFsX2hyZD1ub25lIGZpbGxlcj0wIGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAFliIQBf38SS/E+EWyHM944GSYg'
    'qiwUU/abv7iV39ibqO34RrTmACp+vQCagfyfceDAexsDAlhSYB67V/KScxm+sd0UH1HehtZzfClCPevmPHWjPUcBABXqxFrt'
    'OF5pt85xHXdRbZWUPpjWGIqJVvr4O6QO';

Uint8List _bytes(String base64Text) =>
    Uint8List.fromList(base64Decode(base64Text));

/// 正片分片前缀字节。
final Uint8List contentPrefixBytes = _bytes(contentPrefixBase64);

/// 广告分片前缀字节。
final Uint8List adPrefixBytes = _bytes(adPrefixBase64);
