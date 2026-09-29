import 'dart:async';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/runtime/request_scheduler.dart';

/// Serial ownership of a browser, with an end-to-end deadline including queue
/// time. The callbacks capture only this task's controller, never its successor.
class WebViewTaskQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>({
    required Duration timeout,
    required Future<T> Function(SourceOperation operation) action,
    required Future<void> Function() cleanup,
    required void Function() discard,
    required T Function() onExpired,
    SourceOperation? parent,
    RequestCancelToken? owner,
    Duration cleanupTimeout = const Duration(seconds: 2),
  }) async {
    final operation = SourceOperation(
      parent: parent ?? SourceOperation.current,
      timeout: timeout,
    );
    final detach = owner?.onCancel(operation.cancel);
    final result = _tail.then((_) async {
      if (operation.isCancelled) return onExpired();
      final execution = SourceOperation(parent: operation);
      var completed = false;
      try {
        final value = await execution.run(() => action(execution));
        completed = true;
        return value;
      } on RequestCancelledException {
        return onExpired();
      } finally {
        execution.cancel();
        execution.close(); // Late platform completions cannot start more work.
        if (!completed) {
          discard();
        } else {
          final cleanupOperation = SourceOperation(timeout: cleanupTimeout);
          try {
            await cleanupOperation.run(cleanup);
          } catch (_) {
            discard();
          } finally {
            cleanupOperation.cancel();
            cleanupOperation.close();
          }
        }
      }
    });
    _tail = result.then((_) {}, onError: (Object _) {});
    try {
      return await operation.wait(result);
    } on RequestCancelledException {
      return onExpired();
    } finally {
      detach?.call();
      operation.close();
    }
  }
}
