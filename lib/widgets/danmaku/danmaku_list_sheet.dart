import 'package:baka/api/bgm.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';

/// 居中对话框形态展示的弹幕来源与检索面板
class DanmakuListSheet extends StatefulWidget {
  final DanmakuController controller;
  final String? defaultTitle;
  final int? defaultEpisode;
  final bool initialShowSearch;
  final ValueChanged<List<DanmakuItem>>? onDanmakuLoaded;

  const DanmakuListSheet({
    required this.controller,
    this.defaultTitle,
    this.defaultEpisode,
    this.initialShowSearch = false,
    this.onDanmakuLoaded,
    super.key,
  });

  static Future<void> show(
    BuildContext context,
    DanmakuController controller, {
    String? defaultTitle,
    int? defaultEpisode,
    bool initialShowSearch = false,
    ValueChanged<List<DanmakuItem>>? onDanmakuLoaded,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: DanmakuListSheet(
            controller: controller,
            defaultTitle: defaultTitle,
            defaultEpisode: defaultEpisode,
            initialShowSearch: initialShowSearch,
            onDanmakuLoaded: onDanmakuLoaded,
          ),
        ),
      ),
    );
  }

  @override
  State<DanmakuListSheet> createState() => _DanmakuListSheetState();
}

class _DanmakuListSheetState extends State<DanmakuListSheet> {
  final _searchController = TextEditingController();
  late bool _showSearch;
  bool _isSearching = false;
  String? _searchError;
  List<BgmSubjectInfo> _searchResults = const [];
  BgmSubjectInfo? _selectedSubject;
  Future<List<int>>? _episodes;
  (int, int)? _loadingEpisode;
  int _searchRequest = 0;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _showSearch = widget.initialShowSearch;
    _searchController.text = widget.defaultTitle?.trim() ?? '';
    if (_showSearch) _doSearch(_searchController.text);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _doSearch(String keyword) async {
    final clean = keyword.trim();
    if (clean.isEmpty) return;
    final request = ++_searchRequest;
    setState(() {
      _isSearching = true;
      _searchError = null;
      _searchResults = const [];
      _selectedSubject = null;
      _episodes = null;
    });
    try {
      final results = await searchBgmSubjects(clean);
      if (!mounted || request != _searchRequest) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
        _searchError = results.isEmpty ? '未找到相关番剧' : null;
      });
      if (results.isNotEmpty) _selectSubject(results.first);
    } catch (e) {
      if (!mounted || request != _searchRequest) return;
      setState(() {
        _isSearching = false;
        _searchError = '搜索失败: $e';
      });
    }
  }

  void _selectSubject(BgmSubjectInfo subject) {
    if (_selectedSubject?.subjectId == subject.subjectId) return;
    setState(() {
      _selectedSubject = subject;
      // The API already caches and deduplicates episode requests.
      _episodes = getBgmEpisodes(subject.subjectId).then(
        (episodes) => [
          for (final episode in episodes)
            if ((episode['sort'] as num) > 0) (episode['sort'] as num).round(),
        ],
      );
    });
  }

  Future<void> _loadDanmaku(BgmSubjectInfo subject, int episode) async {
    final selection = (subject.subjectId, episode);
    if (_loadingEpisode == selection) return;
    final request = ++_loadRequest;
    setState(() => _loadingEpisode = selection);
    try {
      final items = await DanmakuController.fetchDanmaku(
        subjectId: subject.subjectId,
        episodeIndex: episode,
        titles: subject.searchTitles,
      );
      if (!mounted || request != _loadRequest) return;
      widget.controller.setItems(items);
      widget.onDanmakuLoaded?.call(items);
      final title = subject.nameCn ?? subject.name ?? '动画';
      showSnackBar(
        '已关联《$title》第 $episode 话 (${items.isEmpty ? "无弹幕" : "${items.length} 条弹幕"})',
      );
      setState(() {
        _loadingEpisode = null;
        _showSearch = false;
      });
    } catch (e) {
      if (!mounted || request != _loadRequest) return;
      setState(() => _loadingEpisode = null);
      showSnackBar('关联失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.subtitles_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('弹幕管理', style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              '${widget.defaultTitle ?? "未指定番剧"} · ${widget.defaultEpisode == null ? "未指定集数" : "第 ${widget.defaultEpisode} 话"}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => Text(
                '来源: dandanplay · ${widget.controller.items.length} 条弹幕',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const Divider(height: 24),
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) => Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                children: [
                  Text(
                    '延迟 ${widget.controller.timeOffset.toStringAsFixed(1)}s',
                  ),
                  for (final delta in [-0.5, 0.0, 0.5])
                    TextButton(
                      onPressed: () => widget.controller.setTimeOffset(
                        delta == 0
                            ? 0
                            : (widget.controller.timeOffset * 10 + delta * 10)
                                      .round() /
                                  10,
                      ),
                      child: Text(
                        delta == 0 ? '重置' : '${delta > 0 ? "+" : ""}${delta}s',
                      ),
                    ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: () {
                setState(() => _showSearch = !_showSearch);
                if (_showSearch && _searchResults.isEmpty && !_isSearching) {
                  _doSearch(_searchController.text);
                }
              },
              icon: Icon(_showSearch ? Icons.expand_less : Icons.search),
              label: Text(_showSearch ? '收起检索' : '手动检索'),
            ),
            if (_showSearch) _buildSearchPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchPanel() {
    final subject = _selectedSubject;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: _doSearch,
          decoration: InputDecoration(
            hintText: '输入番剧名称搜索...',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '清空',
                  onPressed: _searchController.clear,
                  icon: const Icon(Icons.clear),
                ),
                IconButton(
                  tooltip: '检索',
                  onPressed: _isSearching
                      ? null
                      : () => _doSearch(_searchController.text),
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
        ),
        if (_isSearching) const LinearProgressIndicator(),
        if (_searchError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _searchError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_searchResults.isNotEmpty)
          SizedBox(
            height: 56,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _searchResults.length,
              itemBuilder: (context, index) {
                final item = _searchResults[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(item.nameCn ?? item.name ?? '未知'),
                    selected: subject?.subjectId == item.subjectId,
                    onSelected: (_) => _selectSubject(item),
                  ),
                );
              },
            ),
          ),
        if (subject != null) ...[
          const Text('选择集数'),
          const SizedBox(height: 8),
          FutureBuilder<List<int>>(
            future: _episodes,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const LinearProgressIndicator();
              }
              if (snapshot.hasError) return const Text('剧集加载失败');
              final episodes = snapshot.data ?? const [];
              if (episodes.isEmpty) return const Text('暂无集数信息');
              return SizedBox(
                height: 48,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: episodes.length,
                  itemBuilder: (context, index) {
                    final episode = episodes[index];
                    final loading =
                        _loadingEpisode == (subject.subjectId, episode);
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: loading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text('E$episode'),
                        selected: widget.defaultEpisode == episode,
                        onSelected: loading
                            ? null
                            : (_) => _loadDanmaku(subject, episode),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}
