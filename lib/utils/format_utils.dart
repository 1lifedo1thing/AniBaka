const int _kb = 1024;
const int _mb = 1024 * 1024;
const int _gb = 1024 * 1024 * 1024;

String formatBytes(int bytes) {
  if (bytes < _kb) return '$bytes B';
  if (bytes < _mb) return '${(bytes / _kb).toStringAsFixed(1)} KB';
  if (bytes < _gb) return '${(bytes / _mb).toStringAsFixed(1)} MB';
  return '${(bytes / _gb).toStringAsFixed(2)} GB';
}

String formatBytesPerSecond(double bytesPerSecond) {
  if (bytesPerSecond < _kb) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  if (bytesPerSecond < _mb) {
    return '${(bytesPerSecond / _kb).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / _mb).toStringAsFixed(1)} MB/s';
}

const _kEnDays = ['Mon', 'Tue', 'Wed', 'Thur', 'Fri', 'Sat', 'Sun'];
const _kEnMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'June',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _kZhDays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

extension DateTimeFormatting on DateTime {
  /// "Thur, 13 Nov 2023"
  String toEnDate() =>
      '${_kEnDays[weekday - 1]}, $day ${_kEnMonths[month - 1]} $year';

  /// "周三, 14:30"
  String toZhWeekTime() {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '${_kZhDays[weekday - 1]}, $h:$m';
  }

  /// "3分钟前" / "2天前" / "2023-11-13"（超过一年显示日期）
  String toRelativeTime() {
    final diff = DateTime.now().difference(this);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    if (diff.inDays < 365) return '${diff.inDays ~/ 30}个月前';
    return '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
  }
}

extension DurationExtension on Duration {
  Duration clamp(Duration min, Duration max) {
    if (this < min) return min;
    if (this > max) return max;
    return this;
  }

  /// MM:SS / HH:MM:SS；reference 用于让进度与总时长保持相同位数。
  /// 长视频可用 includeDays 显示 DDD:HH:MM:SS。
  String toTimeString({Duration? reference, bool includeDays = false}) {
    final total = reference ?? this;
    final seconds = inSeconds;
    final minutes = inMinutes;
    final hours = inHours;
    final showDays = includeDays && total >= const Duration(days: 1);
    final showHours = total >= const Duration(hours: 1);
    final mm = (showHours ? minutes - hours * 60 : minutes).toString().padLeft(
      2,
      '0',
    );
    final ss = (seconds - minutes * 60).toString().padLeft(2, '0');
    if (!showHours) return '$mm:$ss';
    final days = showDays ? inDays : 0;
    final hh = (showDays ? hours - days * 24 : hours).toString().padLeft(
      2,
      '0',
    );
    return showDays
        ? '${days.toString().padLeft(3, '0')}:$hh:$mm:$ss'
        : '$hh:$mm:$ss';
  }
}

final _compactDate = RegExp(r'^\d{8}');

/// API dates are YYYY-MM-DD; legacy post timestamps also use YYYYMMDD.
String formatDate(String raw) {
  if (_compactDate.hasMatch(raw)) {
    return '${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6, 8)}';
  }
  return raw.length > 10 ? raw.substring(0, 10) : raw;
}
