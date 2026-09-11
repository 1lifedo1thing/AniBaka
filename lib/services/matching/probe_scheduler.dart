import 'dart:async';
import 'dart:collection';

/// 有界并发、按键去重的探针调度器。
///
/// 自动匹配要求「先到先探、随时可停」：命中后必须立刻停止后续工作，
/// 硬截止到达时也不能留下未收尾的批次。调度器只负责并发、去重与队列
/// 语义，具体探针逻辑由 [run] 提供，便于脱离控制器单独测试。
class ProbeScheduler<T> {
  ProbeScheduler({
    required int concurrency,
    required String Function(T job) keyOf,
    required Future<void> Function(T job) run,
  }) : _concurrency = concurrency < 1 ? 1 : concurrency,
       // 命名参数不能直接初始化私有字段。
       // ignore: prefer_initializing_formals
       _keyOf = keyOf,
       // ignore: prefer_initializing_formals
       _run = run;

  final int _concurrency;
  final String Function(T job) _keyOf;
  final Future<void> Function(T job) _run;

  final ListQueue<T> _queue = ListQueue<T>();
  final Set<String> _seen = <String>{};
  int _active = 0;
  bool _closed = false;
  Completer<void>? _drained;

  /// 已停止接收新任务（命中、取消或到达硬截止）。
  bool get isClosed => _closed;
  int get activeCount => _active;
  int get queuedCount => _queue.length;
  bool get isBusy => _active > 0 || _queue.isNotEmpty;

  /// 该 key 是否已被接受（排队中、执行中或已完成）。
  bool contains(String key) => _seen.contains(key);

  /// 入队；同一 key 在一次运行内只接受一次。返回是否真正入队。
  bool add(T job) {
    if (_closed || !_seen.add(_keyOf(job))) return false;
    _queue.addLast(job);
    _pump();
    return true;
  }

  /// 停止接收新任务并丢弃队列；在途任务不取消，由自身超时收尾。
  void close() {
    _closed = true;
    _queue.clear();
    _settleDrain();
  }

  /// 重新开始一轮：清空去重记录与队列，供同一控制器重复搜索。
  void reset() {
    _closed = false;
    _queue.clear();
    _seen.clear();
    _settleDrain();
  }

  /// 队列清空且在途任务全部结束后完成。
  Future<void> get drained {
    if (!isBusy) return Future<void>.value();
    return (_drained ??= Completer<void>()).future;
  }

  void _pump() {
    while (!_closed && _active < _concurrency && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _active++;
      unawaited(
        _run(job)
            .then<void>((_) {}, onError: (Object _, StackTrace _) {})
            .whenComplete(() {
              _active--;
              if (!_closed) _pump();
              _settleDrain();
            }),
      );
    }
    _settleDrain();
  }

  void _settleDrain() {
    if (isBusy) return;
    final done = _drained;
    _drained = null;
    if (done != null && !done.isCompleted) done.complete();
  }
}
