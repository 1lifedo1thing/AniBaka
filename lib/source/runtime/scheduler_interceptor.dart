import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:baka/source/runtime/source_operation.dart';

import 'package:baka/source/runtime/request_scheduler.dart';

/// 把 Dio 请求接入 [RequestScheduler] 的拦截器。
///
/// 挂到适配器共享的 Dio 上后，**所有源**（内置源、v1 规则源、v2 管线源）的
/// HTTP 请求自动获得全局优先级调度与 per-host 限流，无需各适配器自行改造。
///
/// 调用方可通过 request options 的 extra 传递调度参数：
/// - [priorityKey]: [RequestPriority]
class SchedulerInterceptor extends Interceptor {
  static const String priorityKey = 'anx.priority';

  SchedulerInterceptor({RequestScheduler? scheduler})
    : scheduler = scheduler ?? RequestScheduler.instance;
  final RequestScheduler scheduler;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final host = options.uri.host;
    final p = options.extra[priorityKey];
    final priority = p is RequestPriority ? p : RequestPriority.search;
    final operation = SourceOperation.current;
    final cancel = options.cancelToken ??= CancelToken();
    // Tokens created here bypass Options.compose, which normally binds this.
    cancel.requestOptions ??= options;
    final detach = operation?.token.onCancel(
      () => cancel.cancel('source operation cancelled'),
    );
    options.extra['anx.detach'] = detach;
    final queuedCancel = RequestCancelToken();
    if (cancel.isCancelled) queuedCancel.cancel();
    cancel.whenCancel.then((_) {
      queuedCancel.cancel();
      // A shared token's error may point at another request. Release this
      // request's slot directly, even if Dio skips or delays its error chain.
      _release(options);
    });
    try {
      await scheduler.acquire(
        host,
        priority: priority,
        cancelToken: queuedCancel,
      );
    } on RequestCancelledException {
      _release(options);
      handler.reject(cancel.cancelError!);
      return;
    }
    options.extra['anx.acquired'] = host;
    if (cancel.isCancelled) {
      _release(options);
      handler.reject(cancel.cancelError!);
      return;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.data case final ResponseBody body) {
      final options = response.requestOptions;
      // Take ownership from RequestOptions: retries may reuse that object.
      final host = options.extra.remove('anx.acquired');
      final detach = options.extra.remove('anx.detach') as void Function()?;
      var released = false;
      void release() {
        if (released) return;
        released = true;
        detach?.call();
        if (host is String) scheduler.release(host);
      }

      StreamSubscription<Uint8List>? subscription;
      late StreamController<Uint8List> controller;
      Future<void>? cancelling;
      Future<void> closeBody() async {
        release();
        if (subscription != null) {
          await subscription!.cancel();
        } else {
          await body.stream.listen(null, onError: (Object _) {}).cancel();
        }
      }

      Future<void> cancelBody() => cancelling ??= closeBody();
      controller = StreamController<Uint8List>(
        sync: true,
        onListen: () {
          if (released) {
            unawaited(controller.close());
            return;
          }
          subscription = body.stream.listen(
            controller.add,
            onError: (Object e, StackTrace s) {
              release();
              controller.addError(e, s);
              unawaited(subscription?.cancel());
              unawaited(controller.close());
            },
            onDone: () {
              release();
              unawaited(controller.close());
            },
          );
        },
        onPause: () => subscription?.pause(),
        onResume: () => subscription?.resume(),
        onCancel: cancelBody,
      );
      options.cancelToken?.whenCancel.then((_) {
        if (!released) {
          unawaited(cancelBody());
          unawaited(controller.close());
        }
      });
      response.data = ResponseBody(
        controller.stream,
        body.statusCode,
        headers: body.headers,
        statusMessage: body.statusMessage,
        isRedirect: body.isRedirect,
        redirects: body.redirects,
        onClose: () {
          unawaited(cancelBody());
          unawaited(controller.close());
        },
      )..extra = body.extra;
    } else {
      _release(response.requestOptions);
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _release(err.requestOptions);
    handler.next(err);
  }

  void _release(RequestOptions options) {
    (options.extra.remove('anx.detach') as void Function()?)?.call();
    final host = options.extra.remove('anx.acquired');
    if (host is String) scheduler.release(host);
  }
}
