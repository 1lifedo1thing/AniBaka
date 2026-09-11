import 'dart:async';
import 'dart:collection';

/// Bounded cache for shared asynchronous requests.
///
/// The cached value is the Future itself, so concurrent callers share one
/// request and one parse. Failed requests are removed immediately.
final class RequestCache<K, V> {
  RequestCache({required this.limit, this.ttl, this.shouldCache})
    : assert(limit > 0);

  final int limit;
  final Duration? ttl;
  final bool Function(V value)? shouldCache;
  final LinkedHashMap<K, _RequestEntry<V>> _entries = LinkedHashMap();
  // Capacity/TTL apply to completed values. Evicting a running request would
  // start duplicate I/O and parsing when callers outnumber cache slots.
  final Map<K, Future<V>> _pending = {};

  Future<V> get(K key, Future<V> Function() load, {bool refresh = false}) {
    final active = _pending[key];
    if (active != null) return active;
    final cached = _entries.remove(key);
    if (!refresh &&
        cached != null &&
        (cached.expiresAt == null ||
            DateTime.now().millisecondsSinceEpoch < cached.expiresAt!)) {
      _entries[key] = cached;
      return cached.value;
    }

    final completion = Completer<V>();
    final request = completion.future;
    _pending[key] = request;
    completion.complete(
      Future<V>.sync(load).then(
        (value) {
          if (identical(_pending[key], request)) {
            _pending.remove(key);
            if (shouldCache?.call(value) != false) {
              _evictForRoom();
              _entries[key] = _RequestEntry(
                request,
                ttl == null
                    ? null
                    : DateTime.now().millisecondsSinceEpoch +
                          ttl!.inMilliseconds,
              );
            }
          }
          return value;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_pending[key], request)) _pending.remove(key);
          Error.throwWithStackTrace(error, stackTrace);
        },
      ),
    );
    return request;
  }

  void remove(K key) {
    _entries.remove(key);
    _pending.remove(key);
  }

  /// 直接登记一个已算好的值（例如探针已解析出的播放数据）。
  void put(K key, V value) {
    _pending.remove(key);
    _entries.remove(key);
    if (shouldCache?.call(value) == false) return;
    _evictForRoom();
    _entries[key] = _RequestEntry(
      Future<V>.value(value),
      ttl == null
          ? null
          : DateTime.now().millisecondsSinceEpoch + ttl!.inMilliseconds,
    );
  }

  void clear() {
    _entries.clear();
    _pending.clear();
  }

  void _evictForRoom() {
    while (_entries.length >= limit) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// Shares only an in-flight request; completed values are never retained.
final class RequestDeduplicator<K, V> {
  final Map<K, Future<V>> _requests = {};

  Future<V> run(K key, Future<V> Function() load) {
    final active = _requests[key];
    if (active != null) return active;

    final completion = Completer<V>();
    final request = completion.future;
    _requests[key] = request;
    completion.complete(
      Future<V>.sync(load).whenComplete(() {
        if (identical(_requests[key], request)) _requests.remove(key);
      }),
    );
    return request;
  }

  void clear() => _requests.clear();
}

final class _RequestEntry<V> {
  const _RequestEntry(this.value, this.expiresAt);

  final Future<V> value;
  final int? expiresAt;
}
