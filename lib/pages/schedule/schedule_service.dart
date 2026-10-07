import 'package:baka/api/anime_schedule.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/models/anime_schedule.dart';
import 'package:baka/models/bgm.dart';
import 'package:baka/pages/home/home_controller.dart';
import 'package:baka/utils/json_values.dart';

/// Owns only this page's compact metadata; full schedules remain in PostgreSQL.
class ScheduleService {
  ScheduleService({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<int, Future<List<Map<String, dynamic>>>> _episodes = {};
  final Map<(int, String), Future<ScheduleDetails>> _details = {};
  final Map<int, Future<String?>> _covers = {};

  Future<ScheduleWeek> loadWeek(DateTime monday, {bool force = false}) async {
    if (force) {
      _episodes.clear();
      _details.clear();
      _covers.clear();
    }
    Map<String, dynamic>? timetable;
    List<List<Map>>? calendar;
    await Future.wait([
      () async {
        try {
          timetable = await getAnimeSchedule(monday);
          if (timetable!['items'] is! List ||
              timetable!['events'] is! List ||
              timetable!['source'] is! Map ||
              timetable!['site_meta'] is! Map) {
            timetable = null;
          }
        } catch (_) {}
      }(),
      () async {
        try {
          calendar = await HomeController.loadSharedXinfan(force: force);
        } catch (_) {}
      }(),
    ]);
    if (timetable == null && calendar == null) throw StateError('暂时无法获取更新时间表');
    final days = calendar ?? List.generate(7, (_) => <Map>[]);
    try {
      return ScheduleWeek.merge(
        monday: monday,
        calendar: days,
        timetable: timetable,
        calendarUnavailable: calendar == null,
      );
    } on FormatException {
      if (calendar == null) rethrow;
    } on TypeError {
      if (calendar == null) rethrow;
    }
    return ScheduleWeek.merge(monday: monday, calendar: days);
  }

  // Covers must not wait for chapter pagination (or vice versa).
  Future<String?> loadCover(ScheduleEntry entry) {
    final existing = resolveCoverImage(entry.post);
    final id = entry.bgmId;
    if (existing != null || id == null) return Future.value(existing);
    return _covers.putIfAbsent(id, () async {
      try {
        final subject = await getBgmSubject(id, notifyOnError: false);
        return (subject['images'] as Map)['large'] as String;
      } catch (_) {
        return null;
      }
    });
  }

  Future<ScheduleDetails> loadDetails(ScheduleEntry entry) {
    final id = entry.bgmId;
    final date = entry.episodeDate ?? scheduleDate(entry.date);
    final unknown = entry.date.isBefore(scheduleToday(_now()))
        ? '未查到当日章节'
        : '本集信息待公布';
    if (id == null) return Future.value(ScheduleDetails(episodeLabel: unknown));
    return _details.putIfAbsent((id, date), () async {
      try {
        return ScheduleDetails(
          episodeLabel: scheduleEpisodeLabel(
            await _loadEpisodes(id),
            date,
            unknownLabel: unknown,
          ),
        );
      } catch (_) {
        return const ScheduleDetails(episodeLabel: '章节加载失败，下拉重试');
      }
    });
  }

  Future<List<Map<String, dynamic>>> _loadEpisodes(
    int id,
  ) => _episodes.putIfAbsent(id, () async {
    final retained = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final page = await getBgmEpisodePage(id, offset: offset);
      final data = (page['data'] as List).cast<Map<String, dynamic>>();
      // Keep only the fields used below the series title, not episode summaries.
      for (final episode in data) {
        retained.add({
          for (final key in ['airdate', 'sort', 'type', 'name', 'name_cn'])
            key: episode[key],
        });
      }
      offset += data.length;
      final total = toInt(page['total']) ?? offset;
      if (data.isEmpty || offset >= total) break;
      if (offset > 20000) throw const FormatException('章节总数异常');
    }
    return retained;
  });
}
