import 'package:baka/utils/json_values.dart';

/// Shared pagination data; items are passed through without copying.
typedef PageData<T> = ({List<T> list, int total, int page, int pageSize});

PageData<T> parsePage<T>(
  Map<String, dynamic> json,
  T Function(Map<String, dynamic>) parseItem,
) => (
  list: parseList(json['list'], parseItem),
  total: toInt(json['total']) ?? 0,
  page: toInt(json['page']) ?? 1,
  pageSize: toInt(json['page_size']) ?? 20,
);

List<T> parseList<T>(
  Object? value,
  T Function(Map<String, dynamic>) parseItem,
) => (value as List<dynamic>? ?? const [])
    .whereType<Map<String, dynamic>>()
    .map(parseItem)
    .toList(growable: false);
