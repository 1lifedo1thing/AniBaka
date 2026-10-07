/// Shared pagination data; items are passed through without copying.
typedef PageData<T> = ({List<T> list, int total, int page, int pageSize});

PageData<T> parsePage<T>(
  Map<String, dynamic> json,
  T Function(Map<String, dynamic>) parseItem,
) => (
  list: parseList(json['list'], parseItem),
  total: json['total'] as int,
  page: json['page'] as int,
  pageSize: json['page_size'] as int,
);

List<T> parseList<T>(
  Object? value,
  T Function(Map<String, dynamic>) parseItem,
) {
  // Go serializes an empty nil slice as null.
  final items = value as List<dynamic>?;
  if (items == null || items.isEmpty) return const [];
  return List.generate(
    items.length,
    (index) => parseItem(items[index] as Map<String, dynamic>),
    growable: false,
  );
}
