import 'package:baka/utils/json_values.dart';

/// Calendar dates are UTC values used as civil dates, always displayed in UTC+8.
DateTime scheduleToday(DateTime now) {
  final local = now.toUtc().add(const Duration(hours: 8));
  return DateTime.utc(local.year, local.month, local.day);
}

String scheduleDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class SchedulePlatform {
  const SchedulePlatform({
    required this.name,
    required this.time,
    this.url,
    this.regions = const [],
  });
  final String name;
  final String time;
  final Uri? url;
  final List<String> regions;
}

class ScheduleEntry {
  const ScheduleEntry({
    required this.key,
    required this.date,
    required this.post,
    this.bgmId,
    this.at,
    this.time,
    this.episodeDate,
    this.platforms = const [],
    this.premiereOnly = false,
  });
  final String key;
  final int? bgmId;
  final DateTime date;
  final DateTime? at;
  final String? time;
  final String? episodeDate;
  // Share the home calendar entry, including maps restored by Hive.
  final Map post;
  final List<SchedulePlatform> platforms;
  final bool premiereOnly;
  String get title => post['title']?.toString() ?? '未命名番剧';
}

class ScheduleDetails {
  const ScheduleDetails({this.episodeLabel = '本集标题待公布', this.image});
  final String episodeLabel;
  final String? image;
}

class ScheduleWeek {
  const ScheduleWeek({
    required this.monday,
    required this.days,
    this.timingUnavailable = false,
    this.calendarUnavailable = false,
    this.stale = false,
    this.checkedAt,
  });
  final DateTime monday;
  final List<List<ScheduleEntry>> days;
  final bool timingUnavailable;
  final bool calendarUnavailable;
  final bool stale;
  final DateTime? checkedAt;

  factory ScheduleWeek.merge({
    required DateTime monday,
    required List<List<Map>> calendar,
    Map<String, dynamic>? timetable,
    bool calendarUnavailable = false,
  }) {
    final days = List.generate(7, (_) => <ScheduleEntry>[]);
    final posts = <int, Map>{};
    for (final day in calendar) {
      for (final post in day) {
        final id = toInt(post['bgmId']);
        if (id != null) posts[id] = post;
      }
    }
    final records = <String, Map>{};
    final knownScheduleIds = <int>{};
    final timedIds = <int>{};
    final platformEvents = <String, List<Map>>{};
    final events = timetable?['events'] as List? ?? const [];
    for (final raw in timetable?['items'] as List? ?? const []) {
      final record = raw as Map;
      records[record['key'] as String] = record;
      final rules = record['rules'] as List? ?? const [];
      if (rules.isNotEmpty && (rules.first as Map)['timing'] == 'broadcast') {
        final id = toInt(record['bgm_id']);
        if (id != null) knownScheduleIds.add(id);
      }
    }
    for (final raw in events) {
      final event = raw as Map;
      if (event['kind'] == 'platform') {
        (platformEvents[event['key']] ??= []).add(event);
      }
    }
    final meta = timetable?['site_meta'] as Map? ?? const {};
    for (final raw in events) {
      final event = raw as Map;
      if (event['kind'] != 'broadcast') continue;
      final at = DateTime.tryParse(event['at']?.toString() ?? '');
      if (at == null) continue;
      final date = scheduleToday(at);
      final day = date.difference(monday).inDays;
      if (day < 0 || day > 6) continue;
      final record = records[event['key']];
      if (record == null) continue;
      final item = record['item'] as Map;
      final id = toInt(record['bgm_id']);
      if (id != null) timedIds.add(id);
      final post =
          posts[id] ??
          <String, dynamic>{
            'title':
                trimmed(record['name_cn']) ?? trimmed(item['title']) ?? '未命名番剧',
            'source': 'bgm',
            'bgmId': id,
          };
      final local = at.toUtc().add(const Duration(hours: 8));
      // Episode airdate is a date, not a timestamp. Only use a known source zone;
      // Japanese midnight broadcasts can belong to a different UTC+8 day.
      final language = item['lang']?.toString();
      final sourceOffset = language == 'ja'
          ? 9
          : (language?.startsWith('zh') ?? false)
          ? 8
          : null;
      final sourceDate = sourceOffset == null
          ? null
          : scheduleDate(at.toUtc().add(Duration(hours: sourceOffset)));
      final platforms = <SchedulePlatform>[];
      final seen = <String>{};
      final sites = <(String, String), Map>{
        for (final site in item['sites'] as List? ?? const [])
          (site['site'] as String, site['id'] as String): site as Map,
      };
      for (final platform in platformEvents[record['key']] ?? <Map>[]) {
        final platformAt = DateTime.tryParse(platform['at']?.toString() ?? '');
        if (platformAt == null) continue;
        final platformDay = scheduleToday(platformAt);
        final delta = platformDay.difference(date).inDays;
        if (delta != 0 &&
            !(delta == 1 &&
                platformAt.difference(at) <= const Duration(days: 1))) {
          continue;
        }
        final site = platform['site']?.toString() ?? '';
        final siteId = platform['site_id']?.toString() ?? '';
        if (!seen.add('$site/$siteId')) continue;
        final siteData = sites[(site, siteId)];
        final siteMeta = meta[site] as Map? ?? const {};
        final uri = Uri.tryParse(siteData?['url']?.toString() ?? '');
        final time = platformAt.toUtc().add(const Duration(hours: 8));
        platforms.add(
          SchedulePlatform(
            name: siteMeta['title']?.toString() ?? site,
            time:
                '${delta == 1 ? '次日 ' : ''}${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
            url:
                uri != null &&
                    (uri.scheme == 'https' || uri.scheme == 'http') &&
                    uri.host.isNotEmpty
                ? uri
                : null,
            regions:
                ((siteData?['regions'] ?? siteMeta['regions']) as List? ??
                        const [])
                    .cast<String>(),
          ),
        );
      }
      days[day].add(
        ScheduleEntry(
          key: '${record['key']}/${at.toUtc().toIso8601String()}',
          bgmId: id,
          date: date,
          at: at,
          time:
              '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
          episodeDate: sourceDate,
          post: post,
          platforms: platforms,
          premiereOnly: event['timing'] == 'premiere_only',
        ),
      );
    }
    for (var day = 0; day < 7; day++) {
      final seen = <int>{};
      for (final post in day < calendar.length ? calendar[day] : <Map>[]) {
        final id = toInt(post['bgmId']);
        if (id == null ||
            !seen.add(id) ||
            timedIds.contains(id) ||
            knownScheduleIds.contains(id)) {
          continue;
        }
        days[day].add(
          ScheduleEntry(
            key: 'unknown/$id/$day',
            bgmId: id,
            date: monday.add(Duration(days: day)),
            post: post,
          ),
        );
      }
      days[day].sort((a, b) {
        if (a.at == null && b.at != null) return 1;
        if (a.at != null && b.at == null) return -1;
        final time = a.at?.compareTo(b.at!) ?? 0;
        return time != 0 ? time : a.title.compareTo(b.title);
      });
    }
    final source = timetable?['source'] as Map?;
    return ScheduleWeek(
      monday: monday,
      days: days,
      timingUnavailable: timetable == null,
      calendarUnavailable: calendarUnavailable,
      stale: source?['stale'] == true,
      checkedAt: DateTime.tryParse(source?['checked_at']?.toString() ?? ''),
    );
  }
}

/// Exact-date matches only; never calculate the episode number from week count.
String scheduleEpisodeLabel(
  List<Map<String, dynamic>> episodes,
  String? date, {
  String unknownLabel = '本集标题待公布',
}) {
  if (date == null) return unknownLabel;
  final matched =
      episodes
          .where((e) => e['airdate'] == date && (toInt(e['type']) ?? 0) == 0)
          .toList()
        ..sort(
          (a, b) =>
              (toDouble(a['sort']) ?? 0).compareTo(toDouble(b['sort']) ?? 0),
        );
  if (matched.isEmpty) return unknownLabel;
  return matched
      .map((episode) {
        final sort = toDouble(episode['sort']);
        final number = sort == null || sort <= 0
            ? ''
            : '第 ${sort == sort.roundToDouble() ? sort.toInt() : sort} 话 · ';
        final title =
            trimmed(episode['name_cn']) ??
            trimmed(episode['name']) ??
            '本集标题待公布';
        return '$number$title';
      })
      .join('\n');
}
