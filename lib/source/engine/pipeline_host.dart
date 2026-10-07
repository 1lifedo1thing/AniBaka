import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/runtime/request_scheduler.dart';

/// The pipeline's I/O boundary. Parsing uses the shared parsers directly.
abstract class PipelineHost {
  /// 是否允许 WebView 渲染/嗅探。
  bool get allowWebview;

  /// 经调度器发起 HTTP 请求，返回响应体文本。
  /// [operation] defaults to the current source operation inherited by async work.
  ///
  /// [contentType] 为 `form` 时以 `application/x-www-form-urlencoded` 发送 Map
  /// 请求体；默认按 Dio 常规（Map→JSON）处理。
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    SourceOperation? operation,
    RequestPriority priority = RequestPriority.search,
  });

  /// WebView 渲染取页面 HTML；未启用返回空串。
  ///
  /// 管线里的 `sniff(goal: html)` 可以通过 [isReady] 把规则声明的就绪条件
  /// 传到底层 WebView，配合 [timeout] / [settleDelay] 避免在 JS challenge
  /// 或客户端渲染尚未完成时过早读取 HTML。
  Future<String> renderWithWebview(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = Duration.zero,
  });

  /// WebView 嗅探视频直链；未启用返回空串。
  Future<String> sniffWithWebview(String url);
}
