import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/app/navigation.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';

/// 视频源搜索与线路切换底部滑栏
class VideoSourceSearchSheet extends StatefulWidget {
  final Map<String, dynamic> seedData;
  final int targetEpisodeIndex;
  final int currentEpisodeIndex;
  final int currentLineIndex;
  final String? currentSource;
  final VideoSourceSearchController? searchController;
  final String? heroTag;

  const VideoSourceSearchSheet({
    required this.seedData,
    this.targetEpisodeIndex = 0,
    this.currentEpisodeIndex = 0,
    this.currentLineIndex = 1,
    this.currentSource,
    this.searchController,
    this.heroTag,
    super.key,
  });

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required Map<String, dynamic> seedData,
    int currentEpisodeIndex = 0,
    int currentLineIndex = 1,
    String? currentSource,
    VideoSourceSearchController? searchController,
    String? heroTag,
  }) => showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    constraints: const BoxConstraints(maxWidth: 860),
    builder: (_) => VideoSourceSearchSheet(
      seedData: seedData,
      targetEpisodeIndex: currentEpisodeIndex,
      currentEpisodeIndex: currentEpisodeIndex,
      currentLineIndex: currentLineIndex,
      currentSource: currentSource,
      searchController: searchController,
      heroTag: heroTag,
    ),
  );

  @override
  State<VideoSourceSearchSheet> createState() => _VideoSourceSearchSheetState();
}

class _VideoSourceSearchSheetState extends State<VideoSourceSearchSheet> {
  static const _identityKeys = ['seriesId', 'seriesUrl', 'id', 'url'];

  late final VideoSourceSearchController _controller;
  String _selectedFilter = 'all';
  late List<String> _sourceKeys;
  final _meta = SourceMetaLookup();

  late final Set<String> _currentIds;
  late final String _title;
  late final String _cover;
  late final double? _score;
  late final int? _scoreCount;

  List<DirectSourceGroup> _routes = const [];
  String? _selectingKey;

  bool get _isSelecting => _selectingKey != null;
  bool get _isFromPlayer =>
      widget.currentSource != null || widget.searchController != null;

  @override
  void initState() {
    super.initState();
    final seed = widget.seedData;
    _title = seed['title']?.toString().trim() ?? '';
    _cover = BgmUtils.resolveCoverImage(seed) ?? '';
    _score = BgmUtils.readFromData(seed).score;
    final rating = BgmUtils.asMap(
      BgmUtils.asMap(seed['bgmDetailData'])?['rating'],
    );
    _scoreCount = BgmUtils.toInt(rating?['total']);

    _currentIds = {
      for (final key in _identityKeys)
        if (seed[key]?.toString().trim() case final String v when v.isNotEmpty)
          v,
    };

    _controller =
        widget.searchController ??
        VideoSourceSearchController(
          seedData: seed,
          targetEpisodeIndex: widget.targetEpisodeIndex,
        );

    _sourceKeys = _currentSourceKeys();

    _controller.addListener(_onCandidatesChanged);

    _controller.ensureAdapterReady().then((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _sourceKeys = _currentSourceKeys();
        _meta.clear();
      });
    });

    if (_controller.results.isEmpty && !_controller.isSearching) {
      _controller.startSearch();
    }
  }

  List<String> _currentSourceKeys() => [
    'all',
    'internal',
    for (final s in sourceCatalog.quickSearchSources) s.key,
    for (final s in sourceCatalog.enabledCustomSources)
      AdapterRegistry.customSourceKey(s.id),
  ];

  @override
  void dispose() {
    _controller.removeListener(_onCandidatesChanged);
    if (widget.searchController == null &&
        !VideoSourceSearchController.isGlobalCached(_controller)) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _onCandidatesChanged() {
    if (mounted) setState(() {});
  }

  bool _matchesCurrent(SourceCandidateState origin) {
    if (_currentIds.isEmpty ||
        origin.item.sourceType != widget.currentSource ||
        (origin.probe.resolvedLineIndex ?? origin.probe.preferredLine) !=
            widget.currentLineIndex) {
      return false;
    }
    for (final key in _identityKeys) {
      final val = origin.item.data[key]?.toString().trim();
      if (val != null && _currentIds.contains(val)) return true;
    }
    return false;
  }

  Future<void> _selectBest() async {
    if (_isSelecting) {
      return;
    }
    DirectSourceGroup? fallback;
    for (final g in _routes) {
      if (g.isReady) {
        return _selectRoute(g);
      }
      if (fallback == null && g.status != SourceProbeStatus.failed) {
        fallback = g;
      }
    }
    if (fallback != null) {
      return _selectRoute(fallback);
    }
    _message('暂时没有可用线路');
  }

  Future<void> _selectRoute(DirectSourceGroup group) async {
    if (_isSelecting) return;
    final origin = group.primary;
    _controller.markUserSelected();

    setState(() => _selectingKey = group.key);
    try {
      final probe = await _controller.resolveSwitchCandidate(origin);
      final data = probe.data;
      if (!probe.isReady || data == null) {
        _message('线路解析失败，请尝试其他线路');
        return;
      }
      final lineIndex = probe.resolvedLineIndex ?? probe.preferredLine;
      final selectionData = data..['currUrl'] = lineIndex;
      await _controller.persistMatchMemory(origin.item, selectionData);
      if (mounted) {
        if (_isFromPlayer) {
          Navigator.of(context).pop(selectionData);
        } else {
          _navigateToPlayer(selectionData);
        }
      }
    } catch (_) {
      _message('线路解析失败，请尝试其他线路');
    } finally {
      if (mounted) setState(() => _selectingKey = null);
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(text),
            behavior: SnackBarBehavior.floating,
            showCloseIcon: true,
          ),
        );
    }
  }

  Future<void> _showAddAliasDialog() async {
    if (_controller.isSearching) return;
    final textController = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加搜索别名'),
        content: TextField(
          controller: textController,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: '例如 尖帽子的魔法工坊'),
          onSubmitted: (text) => Navigator.pop(dialogContext, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, textController.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    textController.dispose();

    if (!mounted || value == null) {
      return;
    }
    final success = await _controller.addManualAlias(value);
    if (!success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('别名已存在')));
    }
  }

  void _navigateToPlayer(Map<String, dynamic> videoData) {
    if (!mounted) return;
    _controller.cancelSearch();
    VideoSourceSearchController.cacheGlobal(_title, _controller);
    NavigationService.toPlayer(
      context,
      videoData,
      popFirst: true,
      autoMatch: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    _routes = _controller.getDirectSourceGroups(
      episodeIndex: widget.currentEpisodeIndex,
      preferredLine: widget.currentLineIndex,
      currentSource: widget.currentSource,
    );
    if (_routes.any((g) => g.status == SourceProbeStatus.pending)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isSelecting) {
          _controller.startSwitchProbes(_routes.expand((g) => g.origins));
        }
      });
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.76,
      minChildSize: 0.46,
      maxChildSize: 0.96,
      builder: (context, scrollController) => Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildHeaderCard(isDark, primary),
                      _buildErrorBanner(isDark),
                      const SizedBox(height: 12),
                      _buildProgressSection(primary),
                      const SizedBox(height: 8),
                      _buildFilterChips(),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
              _buildResultList(isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderCard(bool isDark, Color primary) {
    final scoreText = (_score ?? 0) > 0 ? _score!.toStringAsFixed(1) : null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCoverThumb(_cover, isDark: isDark),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (_routes.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: _isSelecting ? null : _selectBest,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: _isSelecting
                                ? const SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 18,
                                  ),
                            label: Text(_isSelecting ? '切换中' : '优选'),
                          ),
                        ],
                      ],
                    ),
                    if (scoreText != null &&
                        _scoreCount != null &&
                        _scoreCount > 0) ...[
                      const SizedBox(height: 4),
                      _chipBadge(
                        label: '$scoreText 分 · $_scoreCount 人评分',
                        icon: Icons.star_rounded,
                        color: const Color(0xFFFFC107),
                        bgColor: const Color(
                          0xFFFFC107,
                        ).withValues(alpha: isDark ? 0.22 : 0.16),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.movie_filter_rounded,
                          size: 13,
                          color: primary.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '播放源与线路选择',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildAliasBar(isDark, primary),
        ],
      ),
    );
  }

  Widget _buildAliasBar(bool isDark, Color primary) {
    final isSearching = _controller.isSearching;
    final activeAuto = _controller.activeAutoAliases;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          for (final alias in _controller.automaticAliases)
            _buildAliasTag(
              label: alias,
              color: activeAuto.contains(alias)
                  ? const Color(0xFF66BB6A)
                  : (isDark ? Colors.white30 : Colors.black26),
              icon: activeAuto.contains(alias)
                  ? Icons.auto_awesome_rounded
                  : Icons.add_circle_outline_rounded,
              onTap: isSearching
                  ? null
                  : () => _controller.toggleAutoAlias(alias),
            ),
          for (final alias in _controller.manualAliases)
            _buildAliasTag(
              label: alias,
              color: const Color(0xFF42A5F5),
              icon: Icons.edit_rounded,
              onDelete: isSearching
                  ? null
                  : () => _controller.removeManualAlias(alias),
            ),
          GestureDetector(
            onTap: isSearching ? null : _showAddAliasDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: isDark ? 0.15 : 0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 14, color: primary),
                  const SizedBox(width: 3),
                  Text(
                    '别名',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAliasTag({
    required String label,
    required Color color,
    required IconData icon,
    VoidCallback? onTap,
    VoidCallback? onDelete,
  }) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (onDelete != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onDelete,
                child: Icon(Icons.close_rounded, size: 13, color: color),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _buildErrorBanner(bool isDark) {
    final errors = _controller.searchErrors;
    if (errors.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: Color(0xFFFFB347),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${errors.length} 个来源搜索失败',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _controller.isSearching
                  ? null
                  : _controller.startSearch,
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('重试', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSection(Color primary) {
    final searching = _controller.isSearching;
    final completed = _controller.finishedSources.length;
    final total = _sourceKeys.length - 1;
    final ready = _routes.where((g) => g.isInstantPlayable).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                searching
                    ? '搜索中 · $completed/$total 源'
                    : '搜索完成 · ${_controller.results.length} 个结果',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
            Text(
              '$ready 个可即播',
              style: TextStyle(
                fontSize: 12,
                color: primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            IconButton(
              tooltip: searching ? '停止搜索' : '重新搜索',
              visualDensity: VisualDensity.compact,
              onPressed: searching
                  ? _controller.cancelSearch
                  : _controller.startSearch,
              icon: Icon(
                searching ? Icons.stop_rounded : Icons.refresh_rounded,
                size: 18,
              ),
            ),
          ],
        ),
        if (searching)
          LinearProgressIndicator(
            value: completed == 0
                ? null
                : completed / total.clamp(1, total + 1),
            minHeight: 2,
            borderRadius: BorderRadius.circular(2),
          ),
      ],
    );
  }

  Widget _buildFilterChips() => SizedBox(
    height: 40,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _sourceKeys.length,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (context, index) {
        final key = _sourceKeys[index];
        final meta = _meta[key];
        final count = key == 'all'
            ? _controller.results.length
            : _controller.resultCountFor(key);
        final searching = _controller.progressingSources.contains(key);
        return ChoiceChip(
          selected: _selectedFilter == key,
          showCheckmark: false,
          avatar: Icon(searching ? Icons.sync_rounded : meta.icon, size: 15),
          label: Text('${meta.label} $count'),
          onSelected: (_) => setState(() => _selectedFilter = key),
          visualDensity: VisualDensity.compact,
        );
      },
    ),
  );

  Widget _buildResultList(bool isDark) {
    final colors = Theme.of(context).colorScheme;
    final routes = _selectedFilter == 'all'
        ? _routes
        : [
            for (final group in _routes)
              if (group.origins
                      .where((c) => c.item.sourceType == _selectedFilter)
                      .toList()
                  case final origins when origins.isNotEmpty)
                DirectSourceGroup(
                  key: group.key,
                  origins: origins,
                  status: origins.first.status,
                ),
          ];
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      sliver: routes.isEmpty
          ? SliverToBoxAdapter(
              child: _buildEmptyMessage(
                _controller.isSearching ? '正在搜索视频源…' : '未找到匹配的视频源',
                isDark,
                isLoading: _controller.isSearching,
              ),
            )
          : SliverList.builder(
              itemCount: routes.length,
              itemBuilder: (context, index) => KeyedSubtree(
                key: ValueKey(routes[index].key),
                child: _buildRouteTile(index, routes[index], isDark, colors),
              ),
            ),
    );
  }

  Widget _buildEmptyMessage(
    String message,
    bool isDarkMode, {
    bool isLoading = false,
    bool isSearching = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    decoration: BoxDecoration(
      color: isDarkMode
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.03),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        if (isLoading)
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          )
        else
          Icon(
            Icons.search_off_rounded,
            size: 36,
            color: isDarkMode ? Colors.white38 : Colors.black38,
          ),
        const SizedBox(height: 12),
        Text(
          message,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDarkMode ? Colors.white70 : Colors.black87,
          ),
        ),
        if (!isLoading) ...[
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: isSearching ? null : _controller.startSearch,
            icon: const Icon(Icons.refresh_rounded, size: 15),
            label: const Text('重新搜索', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: const Size(80, 32),
            ),
          ),
        ],
      ],
    ),
  );

  Widget _buildTile({
    required String title,
    required bool isDark,
    Widget? leading,
    List<Widget>? chips,
    Widget? trailing,
    bool isCurrent = false,
    bool isRecommended = false,
    Color? accentColor,
    VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    final accent = accentColor ?? colors.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          splashColor: accent.withValues(alpha: 0.1),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: isCurrent
                  ? colors.primaryContainer.withValues(
                      alpha: isDark ? 0.3 : 0.2,
                    )
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.black.withValues(alpha: 0.03)),
              border: Border.all(
                color: isCurrent
                    ? colors.primary.withValues(alpha: 0.6)
                    : isRecommended
                    ? colors.primary.withValues(alpha: 0.3)
                    : (isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.black.withValues(alpha: 0.06)),
                width: isCurrent ? 1.2 : 1.0,
              ),
            ),
            child: Row(
              children: [
                if (leading != null) ...[leading, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.95)
                              : Colors.black87,
                        ),
                      ),
                      if (chips != null && chips.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Wrap(spacing: 4, runSpacing: 4, children: chips),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRouteTile(
    int index,
    DirectSourceGroup group,
    bool isDark,
    ColorScheme colors,
  ) {
    final labels = <String>{};
    var isCurrent = false;
    for (final origin in group.origins) {
      labels.add(_sourceLabel(origin.item));
      if (!isCurrent && _matchesCurrent(origin)) isCurrent = true;
    }
    final sourcesStr = labels.isEmpty ? '未知来源' : labels.join(' · ');
    final isRecommended = index == 0 && group.isReady && !isCurrent;

    final (statusLabel, statusIcon, statusColor) = switch (group.status) {
      SourceProbeStatus.direct => (
        '可即播',
        Icons.check_circle_rounded,
        colors.primary,
      ),
      SourceProbeStatus.playable => (
        '待取链',
        Icons.play_circle_fill_rounded,
        colors.tertiary,
      ),
      SourceProbeStatus.resolving => (
        '解析中',
        Icons.sync_rounded,
        colors.secondary,
      ),
      SourceProbeStatus.pending => (
        '待检测',
        Icons.schedule_rounded,
        isDark ? Colors.white38 : Colors.black38,
      ),
      SourceProbeStatus.failed => (
        '不可用',
        Icons.error_outline_rounded,
        colors.error,
      ),
    };
    final accent = isCurrent ? colors.primary : statusColor;
    final isSelectingThis = _selectingKey == group.key;

    return _buildTile(
      title: group.primary.item.title,
      isDark: isDark,
      isCurrent: isCurrent,
      isRecommended: isRecommended,
      accentColor: accent,
      onTap: (!_isSelecting || isSelectingThis)
          ? () => _selectRoute(group)
          : null,
      leading: _buildCoverThumb(
        group.primary.item.coverUrl.isNotEmpty
            ? group.primary.item.coverUrl
            : _cover,
        isDark: isDark,
        fallbackIcon: _meta[group.primary.item.sourceType].icon,
        fallbackColor: accent,
      ),
      chips: [
        _chipBadge(label: sourcesStr, color: colors.secondary, isDark: isDark),
        if (group.primary.item.episodeInfo case final info?)
          _chipBadge(label: info, color: colors.secondary, isDark: isDark),
        if (group.primary.item.lineInfo case final info?)
          _chipBadge(label: info, color: colors.secondary, isDark: isDark),
        if (group.primary.item.updateInfo case final info?)
          _chipBadge(label: info, color: colors.secondary, isDark: isDark),
        _chipBadge(label: statusLabel, icon: statusIcon, color: statusColor),
        if (isCurrent)
          _chipBadge(label: '当前线路', color: colors.primary, isDark: isDark),
        if (isRecommended && !isCurrent)
          _chipBadge(label: '优选推荐', color: colors.primary, isDark: isDark),
      ],
      trailing: isSelectingThis
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
            )
          : Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
    );
  }

  Widget _buildCoverThumb(
    String url, {
    required bool isDark,
    IconData? fallbackIcon,
    Color? fallbackColor,
  }) {
    if (url.isEmpty) {
      return Container(
        width: 56,
        height: 74,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: (fallbackColor ?? Colors.grey).withValues(
            alpha: isDark ? 0.2 : 0.12,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          fallbackIcon ?? Icons.tv_rounded,
          color: fallbackColor ?? (isDark ? Colors.white54 : Colors.black38),
          size: 22,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: url,
        memCacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).ceil(),
        fadeInDuration: Duration.zero,
        fit: BoxFit.cover,
        width: 56,
        height: 74,
        errorWidget: (context, url, error) => Container(
          width: 56,
          height: 74,
          color: isDark ? Colors.white10 : Colors.black12,
          alignment: Alignment.center,
          child: const Icon(
            Icons.broken_image_rounded,
            size: 18,
            color: Colors.grey,
          ),
        ),
      ),
    );
  }

  Widget _chipBadge({
    required String label,
    required Color color,
    IconData? icon,
    Color? bgColor,
    bool isDark = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: bgColor ?? color.withValues(alpha: isDark ? 0.18 : 0.08),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: color,
              height: 1,
            ),
          ),
        ),
      ],
    ),
  );

  String _sourceLabel(SearchResultItem item) {
    if (item.sourceType == 'internal') {
      return '站内';
    }
    final displayName = item.data['sourceDisplayName']?.toString().trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;
    return _meta[item.sourceType].label;
  }
}

typedef SourceMeta = ({String label, IconData icon, Color color});

/// 来源标签解析结果按 sheet 生命周期记忆化：一次构建会重复查询
/// descriptor / 自定义源列表十余次。
class SourceMetaLookup {
  final Map<String, SourceMeta> _cache = {};

  void clear() => _cache.clear();

  SourceMeta operator [](String key) =>
      _cache.putIfAbsent(key, () => _resolveSourceMeta(key));
}

SourceMeta _resolveSourceMeta(String key) {
  if (key == 'all') {
    return (
      label: '全部',
      icon: Icons.all_inclusive_rounded,
      color: const Color(0xFF9E9E9E),
    );
  }
  if (key == 'internal') {
    return (
      label: '站内',
      icon: Icons.shield_moon_rounded,
      color: const Color(0xFF4CAF50),
    );
  }

  final descriptor = AdapterRegistry.descriptorFor(key);
  if (descriptor != null) {
    return (
      label: descriptor.displayName,
      icon: descriptor.icon,
      color: descriptor.color,
    );
  }

  if (AdapterRegistry.isCustomSource(key)) {
    final id = key.substring(AdapterRegistry.customSourcePrefix.length);
    for (final s in sourceCatalog.enabledCustomSources) {
      if (s.id == id) {
        const colors = [
          Color(0xFF7C4DFF),
          Color(0xFF00BCD4),
          Color(0xFFFF5722),
          Color(0xFF8BC34A),
          Color(0xFFE91E63),
          Color(0xFF3F51B5),
        ];
        return (
          label: s.name,
          icon: Icons.extension_rounded,
          color: colors[s.name.hashCode.abs() % colors.length],
        );
      }
    }
  }
  return (
    label: '其他来源',
    icon: Icons.layers_rounded,
    color: const Color(0xFF9E9E9E),
  );
}
