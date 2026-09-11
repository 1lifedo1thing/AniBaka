import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:baka/api/post.dart';
import 'package:baka/instance.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/bgm_utils.dart';

/// 弹幕控制器：负责整集弹幕数据获取、高效解码、缓存管理、配置持久化与视图驱动。
class DanmakuController extends ChangeNotifier {
  static const String _settingsKey = 'danmaku_settings';
  static const String _blockWordsKey = 'danmaku_block_words';
  static const String _blockRepeatKey = 'danmaku_block_repeat';
  static const String _blockColorKey = 'danmaku_block_color';

  static const int _maxCachedEpisodes = 5;
  static final LinkedHashMap<String, List<DanmakuItem>> _cache =
      LinkedHashMap<String, List<DanmakuItem>>();

  static DanmakuOption _readOption() => _parseOption(
    BgmUtils.parseJsonMap(Instances.sp.getString(_settingsKey)) ?? const {},
  );

  static String getSavedFontFamily() => _readOption().fontFamily;

  static Future<void> setFontFamily(String fontFamily) {
    final normalized = fontFamily == AppFonts.systemFont
        ? AppFonts.systemFont
        : AppFonts.normalizeFont(fontFamily);
    final option = _readOption().copyWith(fontFamily: normalized);
    return Instances.sp.setString(
      _settingsKey,
      jsonEncode(_optionToJson(option)),
    );
  }

  static DanmakuOption _parseOption(Map<String, dynamic> settings) {
    final savedFont = settings['fontFamily'];
    final fontFamily = switch (savedFont) {
      null => AppFonts.defaultFont,
      AppFonts.systemFont => AppFonts.systemFont,
      final String value => AppFonts.normalizeFont(value),
      _ => AppFonts.defaultFont,
    };
    return DanmakuOption(
      fontSize:
          BgmUtils.toDouble(settings['fontSize']) ??
          DanmakuOption.defaultFontSize,
      fontFamily: fontFamily,
      area: BgmUtils.toDouble(settings['area']) ?? 1.0,
      opacity: BgmUtils.toDouble(settings['opacity']) ?? 1.0,
      duration: BgmUtils.toDouble(settings['duration']) ?? 8.0,
      hideTop: settings['hideTop'] == true,
      hideBottom: settings['hideBottom'] == true,
      hideScroll: settings['hideScroll'] == true,
      strokeWidth: BgmUtils.toDouble(settings['strokeWidth']) ?? 2.0,
    );
  }

  static Future<void> saveSettings(DanmakuController controller) async {
    final option = controller.option;
    final preferences = Instances.sp;
    await Future.wait([
      preferences.setString(_settingsKey, jsonEncode(_optionToJson(option))),
      preferences.setString(_blockWordsKey, jsonEncode(controller.blockWords)),
      preferences.setBool(_blockRepeatKey, controller.blockRepeat),
      preferences.setBool(_blockColorKey, controller.blockColor),
    ]);
  }

  static Map<String, dynamic> _optionToJson(DanmakuOption option) => {
    'fontSize': option.fontSize,
    'fontFamily': option.fontFamily,
    'area': option.area,
    'opacity': option.opacity,
    'duration': option.duration,
    'hideTop': option.hideTop,
    'hideBottom': option.hideBottom,
    'hideScroll': option.hideScroll,
    'strokeWidth': option.strokeWidth,
  };

  static void loadSettings(DanmakuController controller) {
    final preferences = Instances.sp;
    final option = _readOption();
    controller.blockWords = BgmUtils.parseJsonList(
      preferences.getString(_blockWordsKey),
    ).map((value) => value.toString()).toList();
    controller.blockRepeat = preferences.getBool(_blockRepeatKey) ?? false;
    controller.blockColor = preferences.getBool(_blockColorKey) ?? false;
    controller.updateOption(option);
  }

  /// 获取弹幕数据，内置 LRU 内存缓存
  static Future<List<DanmakuItem>> fetchDanmaku({
    required int subjectId,
    required int episodeIndex,
    required Iterable<String> titles,
  }) async {
    final cacheKey = '$subjectId-$episodeIndex';
    final cached = _cache.remove(cacheKey);
    if (cached != null) {
      _cache[cacheKey] = cached;
      return cached;
    }

    for (final title in titles) {
      if (title.isEmpty) continue;
      try {
        final raw = await getDanmu(subjectId, episodeIndex, title);
        if (raw.isNotEmpty) {
          final items = decodeDanmaku(raw);
          if (items.isNotEmpty) {
            _cache[cacheKey] = items;
            while (_cache.length > _maxCachedEpisodes) {
              _cache.remove(_cache.keys.first);
            }
            return items;
          }
        }
      } catch (e) {
        debugPrint('获取弹幕失败 ($title): $e');
      }
    }
    return const [];
  }

  /// 快速高效单趟解码弹幕 JSON
  static List<DanmakuItem> decodeDanmaku(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      final rawItems = decoded is List
          ? decoded
          : (decoded is Map ? decoded['data'] as List? ?? const [] : const []);
      if (rawItems.isEmpty) return const [];

      final items = <DanmakuItem>[];
      var previousTime = -1;
      var isSorted = true;

      for (var i = 0; i < rawItems.length; i++) {
        final item = rawItems[i];
        if (item is! Map) continue;
        final text = item['m']?.toString();
        if (text == null || text.isEmpty) continue;

        final params = item['p'];
        if (params is! String) continue;

        final parts = params.split(',');
        if (parts.length < 2) continue;
        final seconds = double.tryParse(parts[0]);
        if (seconds == null) continue;
        final timeMs = (seconds * 1000).round();
        final type = int.tryParse(parts[1]) ?? 1;
        if (type != 1 && type != 4 && type != 5) continue;

        int colorVal = 0xFFFFFF;
        if (parts.length == 3) {
          colorVal = int.tryParse(parts[2]) ?? 0xFFFFFF;
        } else if (parts.length >= 4) {
          colorVal = int.tryParse(parts[3]) ?? 0xFFFFFF;
        }

        if (timeMs < previousTime) isSorted = false;
        previousTime = timeMs;

        items.add(
          DanmakuItem(
            text,
            time: timeMs,
            color: Color(0xFF000000 | (colorVal & 0xFFFFFF)),
            type: type,
          ),
        );
      }

      if (!isSorted) {
        items.sort((a, b) => a.time.compareTo(b.time));
      }
      return items;
    } catch (e) {
      debugPrint('解析弹幕异常: $e');
      return const [];
    }
  }

  /// 序列化弹幕列表为 JSON 字符串
  static String encodeDanmaku(List<DanmakuItem> items) {
    final buffer = StringBuffer('[');
    for (var i = 0; i < items.length; i++) {
      if (i > 0) buffer.write(',');
      final item = items[i];
      buffer
        ..write('{"m":')
        ..write(jsonEncode(item.text))
        ..write(',"p":"')
        ..write((item.time / 1000).toStringAsFixed(3))
        ..write(',')
        ..write(item.type)
        ..write(',')
        ..write(item.color.toARGB32() & 0xFFFFFF)
        ..write('"}');
    }
    buffer.write(']');
    return buffer.toString();
  }

  static const int maxCachedEpisodes = _maxCachedEpisodes;
  static const int maxCachedItems = 50000;

  static Future<List<DanmakuItem>> decode(String raw) async => decodeDanmaku(raw);
  static String encode(List<DanmakuItem> items) => encodeDanmaku(items);

  static void clearCache() => _cache.clear();
  static void clearDanmakuCache() => _cache.clear();

  static void cacheItems(String key, List<DanmakuItem> items) {
    if (items.length > maxCachedItems) return;
    _cache.remove(key);
    _cache[key] = items;
    while (_cache.length > _maxCachedEpisodes) {
      _cache.remove(_cache.keys.first);
    }
  }

  static ({int episodes, int items}) get cacheSize => (
    episodes: _cache.length,
    items: _cache.values.fold<int>(0, (sum, list) => sum + list.length),
  );

  static Iterable<String> get cachedKeys => _cache.keys;

  DanmakuController();

  final Set<DanmakuListener> _listeners = <DanmakuListener>{};

  bool _running = true;
  double _playbackRate = 1.0;
  bool blockRepeat = false;
  bool blockColor = false;
  List<String> blockWords = [];
  List<DanmakuItem> _items = const [];
  DanmakuOption _option = DanmakuOption(
    fontSize: DanmakuOption.defaultFontSize,
  );

  double timeOffset = 0.0;
  Duration? _lastPosition;

  bool get running => _running;
  double get playbackRate => _playbackRate;
  DanmakuOption get option => _option;
  List<DanmakuItem> get items => _items;

  void setTimeOffset(double offsetInSeconds) {
    if (timeOffset == offsetInSeconds) return;
    timeOffset = offsetInSeconds;
    if (_lastPosition != null) {
      syncTime(_lastPosition!);
    }
  }

  set playbackRate(double value) {
    final rate = value > 0 ? value : 1.0;
    if (_playbackRate == rate) return;
    _playbackRate = rate;
    for (final listener in _listeners.toList(growable: false)) {
      listener.onDanmakuPlaybackRateChanged(rate);
    }
  }

  void setItems(List<DanmakuItem> items) {
    _items = items;
    for (final listener in _listeners.toList(growable: false)) {
      listener.onDanmakuItemsChanged();
    }
    notifyListeners();
  }

  void syncTime(Duration position) {
    _lastPosition = position;
    final adjustedPosition = _adjustedPosition(position);
    for (final listener in _listeners.toList(growable: false)) {
      listener.onDanmakuTimeSync(adjustedPosition);
    }
  }

  Duration _adjustedPosition(Duration position) {
    if (timeOffset == 0) return position;
    final offsetMs = (timeOffset * 1000).round();
    final adjustedMs = (position.inMilliseconds - offsetMs).clamp(0, 86400000);
    return Duration(milliseconds: adjustedMs);
  }

  void addItem(DanmakuItem item) {
    if (!_running) return;
    for (final listener in _listeners.toList(growable: false)) {
      listener.onDanmakuInject(item);
    }
  }

  void pause() {
    if (!_running) return;
    _running = false;
    for (final listener in _listeners.toList(growable: false)) {
      listener.onDanmakuPause();
    }
  }

  void resume() {
    if (_running) return;
    _running = true;
    for (final listener in _listeners.toList(growable: false)) {
      listener.onDanmakuResume();
    }
  }

  void reset() {
    _items = const [];
    final position = _lastPosition;
    final adjustedPosition = position == null ? null : _adjustedPosition(position);
    for (final listener in _listeners.toList(growable: false)) {
      listener.onDanmakuReset();
      if (adjustedPosition != null) {
        listener.onDanmakuTimeSync(adjustedPosition);
      }
    }
    notifyListeners();
  }

  void updateOption(DanmakuOption option) {
    final old = _option;
    _option = option;
    for (final listener in _listeners.toList(growable: false)) {
      listener.onDanmakuOptionChanged(option, old);
    }
  }

  bool isBlocked(String text) {
    for (var i = 0; i < blockWords.length; i++) {
      if (text.contains(blockWords[i])) return true;
    }
    return false;
  }

  bool isColorBlocked(Color color) =>
      blockColor && color.toARGB32() != Colors.white.toARGB32();

  void attach(DanmakuListener listener) {
    if (!_listeners.add(listener)) return;
    final position = _lastPosition;
    if (position != null) {
      listener.onDanmakuTimeSync(_adjustedPosition(position));
    }
    if (_running) {
      listener.onDanmakuResume();
    } else {
      listener.onDanmakuPause();
    }
  }

  void detach(DanmakuListener listener) {
    _listeners.remove(listener);
  }
}

abstract interface class DanmakuListener {
  void onDanmakuTimeSync(Duration position);
  void onDanmakuPlaybackRateChanged(double rate);
  void onDanmakuItemsChanged();
  void onDanmakuInject(DanmakuItem item);
  void onDanmakuOptionChanged(DanmakuOption next, DanmakuOption previous);
  void onDanmakuPause();
  void onDanmakuResume();
  void onDanmakuReset();
}

class DanmakuOption {
  final double fontSize;
  final String fontFamily;
  final double area;
  final double duration;
  final double opacity;
  final bool hideTop;
  final bool hideBottom;
  final bool hideScroll;
  final double strokeWidth;

  static double get defaultFontSize {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return 14.0;
      default:
        return 22.0;
    }
  }

  const DanmakuOption({
    this.fontSize = 14,
    this.fontFamily = AppFonts.defaultFont,
    this.area = 1.0,
    this.duration = 8,
    this.opacity = 1.0,
    this.hideBottom = false,
    this.hideScroll = false,
    this.hideTop = false,
    this.strokeWidth = 2.0,
  });

  DanmakuOption copyWith({
    double? fontSize,
    String? fontFamily,
    double? area,
    double? duration,
    double? opacity,
    bool? hideTop,
    bool? hideBottom,
    bool? hideScroll,
    double? strokeWidth,
  }) {
    return DanmakuOption(
      area: area ?? this.area,
      fontSize: fontSize ?? this.fontSize,
      fontFamily: fontFamily ?? this.fontFamily,
      duration: duration ?? this.duration,
      opacity: opacity ?? this.opacity,
      hideTop: hideTop ?? this.hideTop,
      hideBottom: hideBottom ?? this.hideBottom,
      hideScroll: hideScroll ?? this.hideScroll,
      strokeWidth: strokeWidth ?? this.strokeWidth,
    );
  }
}

class DanmakuItem {
  final String text;
  final Color color;
  final int type;
  final int time;

  const DanmakuItem(
    this.text, {
    this.color = Colors.white,
    this.type = 1,
    this.time = 0,
  });
}
