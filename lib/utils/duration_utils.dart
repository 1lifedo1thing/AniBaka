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
    final showDays = includeDays && total > const Duration(days: 1);
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
