import 'package:baka/core/account_session.dart';
import 'package:baka/pages/home/home_controller.dart';
import 'package:baka/pages/mine/mine_profile.dart';
import 'package:baka/widgets/anime/post_card.dart';
import 'package:baka/widgets/common/refresh.dart';
import 'package:baka/widgets/platform/windows/windows_home_widgets.dart';
import 'package:baka/widgets/search/tag_filter_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart' hide ContextExtensionss;

const _weekLabels = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
const _rankLabels = <String>['总榜', '季榜', '月榜', '日榜'];
const _rankHints = <String>['按 Bangumi 排名', '近 90 天开播', '近 30 天开播', '近 2 天开播'];

const double _gutter = 32;
const double _bannerTopGap = 35;

const double _sectionGap = 40;
const double _shelfPosterWidth = 148;
const double _rankPosterWidth = 132;
const double _feedMinTileWidth = 156;
const double _feedColumnGap = 20;
const double _feedRowGap = 28;

/// Windows 桌面版主页。各板块独立订阅数据源，避免整页重建。
class WindowsHomePage extends StatelessWidget {
  const WindowsHomePage({
    required this.svc,
    required this.onRefresh,
    super.key,
  });

  final HomeController svc;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final textHeight = windowsTileTextHeight(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: LayoutBuilder(
        builder: (context, constraints) => RefreshWrapper(
          onLoadMore: svc.loadMore,
          onRefresh: onRefresh,
          loadMoreResetListenable: svc.tag,
          showInitialIndicator: false,
          child: CustomScrollView(
            scrollCacheExtent: const ScrollCacheExtent.pixels(800),
            slivers: [
              _buildBanner(),
              _buildSchedule(textHeight),
              _buildRanks(textHeight),
              _buildFeedHeader(),
              _buildFeedGrid(constraints.maxWidth, textHeight),
              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBanner() {
    return ValueListenableBuilder<HomeItems>(
      valueListenable: svc.swipers,
      builder: (context, swipers, _) {
        if (swipers.isEmpty) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            _gutter,
            _bannerTopGap,
            _gutter,
            0,
          ),
          sliver: SliverToBoxAdapter(child: WindowsHeroBanner(items: swipers)),
        );
      },
    );
  }

  Widget _buildSchedule(double textHeight) {
    return ValueListenableBuilder<List<HomeItems>>(
      valueListenable: svc.schedule,
      builder: (context, schedule, _) {
        if (schedule.every((day) => day.isEmpty)) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverPadding(
          padding: const EdgeInsets.only(top: _sectionGap),
          sliver: SliverToBoxAdapter(
            child: ValueListenableBuilder<int>(
              valueListenable: svc.week,
              builder: (context, week, _) {
                final items = schedule[week];
                final today = DateTime.now().weekday - 1;
                final dayName = week == today ? '今天' : _weekLabels[week];
                return WindowsShelf(
                  title: '每日放送',
                  subtitle: items.isEmpty
                      ? '$dayName暂无更新'
                      : '$dayName · ${items.length} 部',
                  gutter: _gutter,
                  resetKey: week,
                  height: _shelfPosterWidth * 1.5 + textHeight,
                  actions: [
                    WindowsSegmentedTabs(
                      labels: [
                        for (var i = 0; i < _weekLabels.length; i++)
                          i == today ? '今天' : _weekLabels[i],
                      ],
                      selected: week,
                      onChanged: (index) => svc.week.value = index,
                    ),
                  ],
                  placeholder: const _EmptyShelf(message: '这一天没有番剧更新'),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return SizedBox(
                      width: _shelfPosterWidth,
                      child: WindowsPosterTile(
                        data: item,
                        heroTag: 'home_${coverHeroTag(item)}',
                        posIndex: item['index'] ?? 0,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildRanks(double textHeight) {
    return SliverPadding(
      padding: const EdgeInsets.only(top: _sectionGap),
      sliver: SliverToBoxAdapter(
        child: ValueListenableBuilder<int>(
          valueListenable: svc.rankIndex,
          builder: (context, index, _) =>
              ValueListenableBuilder<List<HomeItems>>(
                valueListenable: svc.ranks,
                builder: (context, ranks, _) {
                  final items = ranks[index];
                  return WindowsShelf(
                    title: '热门排行',
                    subtitle: _rankHints[index],
                    gutter: _gutter,
                    resetKey: index,
                    height: _rankPosterWidth * 1.5 + textHeight,
                    actions: [
                      WindowsSegmentedTabs(
                        labels: _rankLabels,
                        selected: index,
                        onChanged: svc.selectRank,
                      ),
                    ],
                    placeholder: WindowsRankSkeleton(
                      posterWidth: _rankPosterWidth,
                      textHeight: textHeight,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, rankIndex) {
                      final item = items[rankIndex];
                      // 排行与下方信息流可能出现同一部番剧，Hero 标签需要单独的前缀。
                      return WindowsPosterTile(
                        data: item,
                        rank: rankIndex + 1,
                        heroTag: 'rank_${coverHeroTag(item)}',
                        posterWidth: _rankPosterWidth,
                      );
                    },
                  );
                },
              ),
        ),
      ),
    );
  }

  Widget _buildFeedHeader() {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(_gutter, _sectionGap + 4, _gutter, 18),
      sliver: SliverToBoxAdapter(
        child: ValueListenableBuilder<String>(
          valueListenable: svc.tag,
          builder: (context, selected, _) => Row(
            children: [
              Text(
                '发现',
                style: WindowsSectionHeader.titleStyle(
                  Theme.of(context).colorScheme,
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: _TagChips(
                  tags: svc.displayTags,
                  selected: selected,
                  onSelected: svc.selectTag,
                ),
              ),
              const SizedBox(width: 12),
              _MoreTagsButton(
                onPressed: () async {
                  final tag = await TagFilterSheet.show(context, selected);
                  if (tag != null && tag.isNotEmpty) await svc.selectTag(tag);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeedGrid(double width, double textHeight) {
    // SliverConstraints 随滚动逐帧变化，列数只需要依赖窗口的可用宽度。
    final available = width - _gutter * 2;
    if (available < _feedMinTileWidth) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final columns =
        ((available + _feedColumnGap) / (_feedMinTileWidth + _feedColumnGap))
            .floor()
            .clamp(2, 10);
    final tileWidth = (available - _feedColumnGap * (columns - 1)) / columns;
    return ValueListenableBuilder<HomeItems>(
      valueListenable: svc.feed,
      builder: (context, items, _) => SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: _gutter),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _feedColumnGap,
            mainAxisSpacing: _feedRowGap,
            mainAxisExtent: tileWidth * 1.5 + textHeight,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final item = items[index];
              return WindowsPosterTile(
                key: ValueKey('feed_${item['bgmId'] ?? item['id'] ?? index}'),
                data: item,
                heroTag: coverHeroTag(item),
              );
            },
            childCount: items.length,
            addAutomaticKeepAlives: false,
          ),
        ),
      ),
    );
  }
}

/// 页面顶部的问候语、日期与今日更新数量，右侧提供刷新入口。
class _Greeting extends StatefulWidget {
  final HomeController svc;

  const _Greeting({required this.svc});

  @override
  State<_Greeting> createState() => _GreetingState();
}

class _GreetingState extends State<_Greeting> {
  bool _refreshing = false;

  static String _salutation(int hour) {
    if (hour < 5) return '夜深了';
    if (hour < 11) return '早上好';
    if (hour < 13) return '中午好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  /// 通过外层 RefreshIndicator 触发刷新，保持与下拉刷新相同的分页重置逻辑。
  Future<void> _refresh() async {
    final indicator = context.findAncestorStateOfType<RefreshIndicatorState>();
    if (indicator == null || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      await indicator.show();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final date = '${now.month}月${now.day}日 · 星期${'一二三四五六日'[now.weekday - 1]}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(_gutter, 16, _gutter, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(() {
                  final session = Get.find<AccountSession>();
                  session.user.value;
                  final salutation = _salutation(now.hour);
                  return Text(
                    session.hasIdentity
                        ? '$salutation，${session.displayName}'
                        : salutation,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 26,
                      height: 1.25,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      color: colors.onSurface,
                    ),
                  );
                }),
                const SizedBox(height: 4),
                ValueListenableBuilder<List<HomeItems>>(
                  valueListenable: widget.svc.schedule,
                  builder: (context, schedule, _) {
                    final count = schedule[now.weekday - 1].length;
                    return Text(
                      count > 0 ? '$date · 今天有 $count 部番剧更新' : date,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton.icon(
            onPressed: _refreshing ? null : _refresh,
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.onSurface,
              side: BorderSide(
                color: colors.outlineVariant.withValues(alpha: 0.8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: _refreshing
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  final String message;

  const _EmptyShelf({required this.message});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event_busy_outlined,
              size: 28,
              color: colors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagChips extends StatelessWidget {
  final List<String> tags;
  final String selected;
  final ValueChanged<String> onSelected;

  const _TagChips({
    required this.tags,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tag in tags)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Material(
                  color: tag == selected
                      ? colors.primary
                      : colors.onSurface.withValues(
                          alpha: isDark ? 0.08 : 0.05,
                        ),
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onSelected(tag),
                    splashFactory: NoSplash.splashFactory,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: tag == selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: tag == selected
                              ? colors.onPrimary
                              : colors.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MoreTagsButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _MoreTagsButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.onSurface,
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.8)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      icon: const Icon(Icons.tune_rounded, size: 17),
      label: const Text('更多标签'),
    );
  }
}
