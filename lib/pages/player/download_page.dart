import 'package:baka/models/playback_request.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:flutter/material.dart';

import 'package:baka/models/download_task.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/services/download/download_manager.dart';

class DownloadManagerPage extends StatefulWidget {
  final bool embedded;

  const DownloadManagerPage({super.key, this.embedded = false});

  static void show(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DownloadManagerPage()));
  }

  @override
  State<DownloadManagerPage> createState() => _DownloadManagerPageState();
}

class _DownloadManagerPageState extends State<DownloadManagerPage> {
  final _service = downloads;
  List<DownloadTask> _active = [];
  List<MapEntry<String, List<DownloadTask>>> _completed = [];

  @override
  void initState() {
    super.initState();
    _readTasks();
    _service.tasksListenable.addListener(_onTasksChanged);
    _service.init();
  }

  @override
  void dispose() {
    _service.tasksListenable.removeListener(_onTasksChanged);
    super.dispose();
  }

  void _onTasksChanged() => setState(_readTasks);

  void _readTasks() {
    final active = <DownloadTask>[];
    final grouped = <String, List<DownloadTask>>{};
    for (final task in _service.tasks.reversed) {
      if (task.status != DownloadStatus.completed) {
        active.add(task);
      } else {
        (grouped[task.title] ??= <DownloadTask>[]).add(task);
      }
    }
    _active = active;
    _completed = grouped.entries.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(widget.embedded ? '下载管理' : '缓存'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (val) {
              if (val == 'pause_all') _service.pauseAll();
              if (val == 'resume_all') _service.resumeAll();
              if (val == 'clear_completed') _service.clearCompleted();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'pause_all', child: Text('全部暂停')),
              PopupMenuItem(value: 'resume_all', child: Text('全部继续')),
              PopupMenuItem(value: 'clear_completed', child: Text('清除已完成记录')),
            ],
          ),
        ],
      ),
      body: _active.isEmpty && _completed.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.download_done_rounded,
                    size: 48,
                    color: theme.disabledColor,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '暂时没有任何下载',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              itemCount:
                  _active.length +
                  _completed.length +
                  (_active.isEmpty ? 0 : 1) +
                  (_completed.isEmpty ? 0 : 1),
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String>) return null;
                final activeIndex = _active.indexWhere(
                  (task) => task.id == key.value,
                );
                if (activeIndex >= 0) return activeIndex + 1;
                final groupIndex = _completed.indexWhere(
                  (group) => 'group_${group.key}' == key.value,
                );
                return groupIndex < 0
                    ? null
                    : (_active.isEmpty ? 0 : _active.length + 1) +
                          groupIndex +
                          1;
              },
              itemBuilder: (context, index) {
                if (_active.isNotEmpty) {
                  if (index == 0) {
                    return _sectionTitle(theme, '下载中 · ${_active.length}');
                  }
                  index--;
                  if (index < _active.length) {
                    final task = _active[index];
                    return _TaskCard(key: ValueKey(task.id), task: task);
                  }
                  index -= _active.length;
                }
                if (index == 0) {
                  return _sectionTitle(theme, '已完成 · ${_completed.length}');
                }
                final group = _completed[index - 1];
                return _AnimeGroupCard(
                  key: ValueKey('group_${group.key}'),
                  title: group.key,
                  tasks: group.value,
                );
              },
            ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

Widget _dismissBackground(ThemeData theme) {
  return Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: theme.colorScheme.error,
      borderRadius: BorderRadius.circular(12),
    ),
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.only(right: 24),
    child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
  );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = ColoredBox(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
      child: Icon(Icons.movie_outlined, color: theme.disabledColor),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 96,
        height: 60,
        child: (url == null || url!.isEmpty)
            ? fallback
            : CachedNetworkImage(
                imageUrl: url!,
                memCacheWidth: 192,
                fit: BoxFit.cover,
                placeholder: (_, _) => fallback,
                errorWidget: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final DownloadTask task;

  const _TaskCard({required this.task, super.key});

  void _onTap(BuildContext context) {
    final service = downloads;
    switch (task.status) {
      case DownloadStatus.downloading:
        service.pause(task);
      case DownloadStatus.paused:
      case DownloadStatus.failed:
      case DownloadStatus.waiting:
        service.resume(task);
      case DownloadStatus.completed:
        if (task.filePath != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlayerPage(
                request: PlaybackRequest.fromMap({
                  'source': '_local',
                  'title': task.title,
                  'episodeTitle': task.subtitle,
                  'localFilePath': task.filePath!,
                  'danmakuPath': task.danmakuPath,
                  'id': 0,
                }),
              ),
            ),
          );
        }
    }
  }

  (String, IconData) _statusInfo(DownloadStatus status) {
    return switch (status) {
      DownloadStatus.waiting => ('等待中', Icons.schedule_rounded),
      DownloadStatus.downloading => ('下载中', Icons.pause_rounded),
      DownloadStatus.paused => ('已暂停', Icons.play_arrow_rounded),
      DownloadStatus.completed => ('已完成', Icons.play_arrow_rounded),
      DownloadStatus.failed => ('下载失败', Icons.refresh_rounded),
    };
  }

  Color _statusColor(ThemeData theme, DownloadStatus status) {
    return switch (status) {
      DownloadStatus.downloading => theme.colorScheme.primary,
      DownloadStatus.paused => const Color(0xFFF59E0B),
      DownloadStatus.failed => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dismissible(
      key: ValueKey('dismiss_${task.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => downloads.delete(task),
      background: _dismissBackground(theme),
      child: ValueListenableBuilder<DownloadStatus>(
        valueListenable: task.statusNotifier,
        builder: (context, status, _) {
          final (statusText, actionIcon) = _statusInfo(status);
          final statusColor = _statusColor(theme, status);

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _onTap(context),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    _Thumbnail(url: task.thumbnail),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            task.subtitle ?? '未知剧集',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (status == DownloadStatus.completed) ...[
                            const SizedBox(height: 4),
                            Text(
                              formatBytes(task.totalBytes),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ] else ...[
                            const SizedBox(height: 8),
                            ValueListenableBuilder<double>(
                              valueListenable: task.progressNotifier,
                              builder: (context, progress, _) => ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: progress.clamp(0.0, 1.0),
                                  minHeight: 3,
                                  backgroundColor: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.08),
                                  color: statusColor,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            ValueListenableBuilder<int>(
                              valueListenable: task.downloadedBytesNotifier,
                              builder: (context, bytes, _) => Text(
                                task.totalBytes > 0
                                    ? '$statusText · ${formatBytes(bytes)} / ${formatBytes(task.totalBytes)}'
                                    : '$statusText · ${(task.progress * 100).toStringAsFixed(0)}%',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      actionIcon,
                      size: 22,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AnimeGroupCard extends StatelessWidget {
  final String title;
  final List<DownloadTask> tasks;

  const _AnimeGroupCard({required this.title, required this.tasks, super.key});

  Future<bool?> _confirmDelete(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除合集'),
        content: Text('确定要删除《$title》的所有已下载剧集吗？这会清除本地文件且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalBytes = tasks.fold(0, (sum, t) => sum + t.totalBytes);

    return Dismissible(
      key: ValueKey('dismiss_group_$title'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) {
        for (final task in tasks) {
          downloads.delete(task);
        }
      },
      background: _dismissBackground(theme),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => _AnimeGroupPage(title: title)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                _Thumbnail(url: tasks.first.thumbnail),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '共 ${tasks.length} 集 · ${formatBytes(totalBytes)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimeGroupPage extends StatefulWidget {
  final String title;

  const _AnimeGroupPage({required this.title});

  @override
  State<_AnimeGroupPage> createState() => _AnimeGroupPageState();
}

class _AnimeGroupPageState extends State<_AnimeGroupPage> {
  final _service = downloads;
  List<DownloadTask> _tasks = [];

  @override
  void initState() {
    super.initState();
    _readTasks();
    _service.tasksListenable.addListener(_onTasksChanged);
  }

  @override
  void dispose() {
    _service.tasksListenable.removeListener(_onTasksChanged);
    super.dispose();
  }

  void _readTasks() {
    _tasks = [
      for (final task in _service.tasks.reversed)
        if (task.title == widget.title) task,
    ];
  }

  void _onTasksChanged() => setState(_readTasks);

  @override
  Widget build(BuildContext context) {
    if (_tasks.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            ModalRoute.of(context)?.isCurrent == true &&
            _tasks.isEmpty &&
            Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: _tasks.length,
        itemBuilder: (context, i) =>
            _TaskCard(key: ValueKey(_tasks[i].id), task: _tasks[i]),
      ),
    );
  }
}
