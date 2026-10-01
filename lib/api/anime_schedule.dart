import 'package:baka/api/api_config.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/models/anime_schedule.dart';

Future<Map<String, dynamic>> getAnimeSchedule(
  DateTime monday,
) => apiTransport.getData<Map<String, dynamic>>(
  Uri.parse('${ApiConfig.host}/api/v1/anime/schedule')
      .replace(
        queryParameters: {
          'date': scheduleDate(monday),
          // Include the following Monday for a Sunday's platform release after midnight.
          'days': '8', 'tz': 'Asia/Shanghai',
        },
      )
      .toString(),
  notifyOnError: false,
);
