import 'package:flutter/foundation.dart';
import 'package:baka/api/post.dart';
import 'package:baka/api/anibaka_api.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/core/app_storage.dart';

/// 单频道运行时状态（数据与加载标志合一，避免平行数组）
class ThreadTab {
  final String name;
  final int pid;
  List comments = [];
  final Set<Object?> seenIds = <Object?>{};
  bool isRefreshing = false;
  bool isLoadingMore = false;
  bool hasMore = true;

  /// 已成功加载的页数；0 表示尚未加载
  int page = 0;
  int revision = 0;
  ThreadTab(this.name, this.pid);
}

/// 帖子/讨论区业务逻辑
///
/// 分页：固定 pageSize，按 page 递增拉取并 append，
/// 避免「每次把 pageSize 加大再整表重拉」的 O(n²) 网络与处理开销。
class ThreadController {
  static const int pageSize = 20;

  /// 评论缓存 1 小时（首页缓存忽略过期，供冷启动快速填充）。
  static final TtlCache _commentsCache = TtlCache(
    AppStorage.threadCommentsBox,
    ttl: const Duration(hours: 1),
  );

  final tabs = [
    ThreadTab('#茶馆', 6),
    ThreadTab('#baka', 8),
    ThreadTab('#求番报错', 7),
    ThreadTab('#反馈', 9),
    ThreadTab('#里世界', 10),
  ];

  List<WatchPartyInvite> watchRooms = const [];
  bool watchRoomsRefreshing = false;
  String watchRoomsError = '';
  Future<List<WatchPartyInvite>>? _watchRoomsTask;

  Future<List<WatchPartyInvite>> refreshWatchRooms() =>
      _watchRoomsTask ??= () async {
        watchRoomsRefreshing = true;
        try {
          final rooms = await AniBakaApi.listWatchRooms();
          watchRooms = rooms;
          watchRoomsError = '';
          return rooms;
        } catch (error) {
          watchRoomsError = error.toString().replaceFirst('Bad state: ', '');
          debugPrint('刷新一起看房间失败: $error');
          rethrow;
        } finally {
          watchRoomsRefreshing = false;
          _watchRoomsTask = null;
        }
      }();

  /// 尝试用本地缓存填充 [tabIndex]；命中返回 true。
  bool loadCached(int tabIndex, {bool ignoreExpiry = true}) {
    final tab = tabs[tabIndex];
    try {
      final cached = _commentsCache.read(
        'raw_comments_${tab.pid}',
        allowExpired: ignoreExpiry,
      );
      if (cached is! List || cached.isEmpty) return false;
      tab.comments = List.of(cached);
      tab.seenIds
        ..clear()
        ..addAll(tab.comments.map((c) => c['id']));
      // 缓存仅包含首页；满页时允许继续分页。
      tab.page = 1;
      tab.hasMore = cached.length >= pageSize;
      return true;
    } catch (e) {
      debugPrint('读取评论缓存失败: $e');
      return false;
    }
  }

  /// 刷新首页。返回最新列表。
  Future<List> refresh(int tabIndex) async {
    final tab = tabs[tabIndex];
    if (tab.isRefreshing) return tab.comments;

    tab.isRefreshing = true;
    ++tab.revision;
    try {
      final list = await getComments(tab.pid, pageSize, '');
      tab.comments = list;
      tab.seenIds
        ..clear()
        ..addAll(tab.comments.map((c) => c['id']));
      tab.page = 1;
      tab.hasMore = list.length >= pageSize;
      try {
        // Hive retains values in memory: appending later pages must not grow this snapshot.
        await _commentsCache.write('raw_comments_${tab.pid}', List.of(list));
      } catch (error) {
        debugPrint('保存评论缓存失败: $error');
      }
      return list;
    } catch (e) {
      debugPrint('刷新评论失败: $e');
      rethrow;
    } finally {
      tab.isRefreshing = false;
    }
  }

  bool canLoadMore(int tabIndex) {
    final tab = tabs[tabIndex];
    // page == 0 表示首页还没成功加载过，此时没有「下一页」可言。
    return tab.page > 0 &&
        !tab.isRefreshing &&
        !tab.isLoadingMore &&
        tab.hasMore;
  }

  /// 原地追加去重后的下一页；过期请求不修改当前列表。
  Future<List?> loadMore(int tabIndex) async {
    if (!canLoadMore(tabIndex)) return null;

    final tab = tabs[tabIndex];
    final nextPage = tab.page + 1;
    final revision = tab.revision;
    tab.isLoadingMore = true;
    try {
      final page = await getComments(tab.pid, pageSize, '', page: nextPage);
      if (revision != tab.revision) return null;
      for (final comment in page) {
        final id = comment['id'];
        if (id == null || tab.seenIds.add(id)) tab.comments.add(comment);
      }
      tab.page = nextPage;
      tab.hasMore = page.length >= pageSize;
      return tab.comments;
    } catch (e) {
      debugPrint('加载更多评论失败: $e');
      return null;
    } finally {
      tab.isLoadingMore = false;
    }
  }
}
