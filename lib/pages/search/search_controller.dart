import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/api/post.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/utils/bgm_utils.dart';

class AnimeSearchController {
  static const int gvMinLength = 2;
  static const int maxHistoryCount = 15;
  static const String _searchHistoryKey = 'search_history';
  static const String noDescriptionText = '暂无描述';

  static const String _isVerticalLayoutKey = 'search_is_vertical_layout';

  final ValueNotifier<List<Map<String, dynamic>>> resultsNotifier =
      ValueNotifier<List<Map<String, dynamic>>>(const []);
  final ValueNotifier<int> selectedSourceIndexNotifier = ValueNotifier<int>(0);
  final ValueNotifier<String> keywordNotifier = ValueNotifier<String>('');
  final ValueNotifier<List<String>> searchHistoryNotifier =
      ValueNotifier<List<String>>(const []);
  final ValueNotifier<bool> showResultsNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isLoadingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> sourceLabelsNotifier =
      ValueNotifier<List<String>>(const ['BGM']);
  final ValueNotifier<bool> isVerticalLayoutNotifier = ValueNotifier<bool>(
    false,
  );

  bool get isVerticalLayout => isVerticalLayoutNotifier.value;
  set isVerticalLayout(bool v) {
    isVerticalLayoutNotifier.value = v;
    Instances.sp.setBool(_isVerticalLayoutKey, v);
  }

  int activeSearchId = 0;
  bool _disposed = false;
  _SearchTask? _running;
  _SearchTask? _pending;
  int _sourceRevision = 0;

  final SourceAdapterService _sourceAdapterService = sourceRepository;
  List<CustomSourceConfig> customSources = [];
  List<AdapterDescriptor> builtinAdapterSources = [];
  Future<void> init({int? initialSource, String? initialKeyword}) async {
    isVerticalLayoutNotifier.value =
        Instances.sp.getBool(_isVerticalLayoutKey) ?? false;
    await reloadCustomSources();
    if (_disposed) return;

    if (initialSource != null &&
        initialSource >= 0 &&
        initialSource < sourceLabelsNotifier.value.length) {
      selectedSourceIndexNotifier.value = initialSource;
    }
    searchHistoryNotifier.value = _loadHistory();
    if (initialKeyword != null) keywordNotifier.value = initialKeyword;
  }

  Future<void> reloadCustomSources() async {
    invalidateSearch();
    _sourceRevision++;
    await _sourceAdapterService.init();
    if (_disposed) return;
    customSources = sourceCatalog.enabledCustomSources;
    builtinAdapterSources = sourceCatalog.enabledBuiltinSources;

    sourceLabelsNotifier.value = List<String>.unmodifiable([
      'BGM',
      ...builtinAdapterSources.map((s) => s.displayName),
      ...customSources.map((s) => s.name),
    ]);

    if (selectedSourceIndexNotifier.value >=
        sourceLabelsNotifier.value.length) {
      selectedSourceIndexNotifier.value = 0;
    }
  }

  String get selectedSourceLabel =>
      selectedSourceIndexNotifier.value >= 0 &&
          selectedSourceIndexNotifier.value < sourceLabelsNotifier.value.length
      ? sourceLabelsNotifier.value[selectedSourceIndexNotifier.value]
      : 'BGM';

  void resetSearch() {
    invalidateSearch();
    keywordNotifier.value = '';
    showResultsNotifier.value = false;
    resultsNotifier.value = const [];
    isLoadingNotifier.value = false;
  }

  bool isActiveSearch(int searchId) => !_disposed && searchId == activeSearchId;

  // Input changes invalidate queued work immediately, before the debounce fires.
  // Running transport work cannot be aborted through every adapter's API.
  void invalidateSearch() {
    activeSearchId++;
    _running?.wanted = false;
    _pending?.completion.complete(const []);
    _pending = null;
  }

  String _sourceKey(int source) {
    if (source == 0) return 'bgm';
    final builtin = source - 1;
    if (builtin >= 0 && builtin < builtinAdapterSources.length) {
      return builtinAdapterSources[builtin].key;
    }
    final custom = builtin - builtinAdapterSources.length;
    return custom >= 0 && custom < customSources.length
        ? AdapterRegistry.customSourceKey(customSources[custom].id)
        : '';
  }

  Future<List<Map<String, dynamic>>> executeSearch(String searchKey) {
    if (_disposed) return SynchronousFuture(const []);
    final query = searchKey.trim();
    if (query.isEmpty) {
      invalidateSearch();
      return SynchronousFuture(const []);
    }

    keywordNotifier.value = query;
    final source = _sourceKey(selectedSourceIndexNotifier.value);
    final key = (source: source, query: query, revision: _sourceRevision);
    if (_pending?.key == key) return _pending!.completion.future;
    _pending?.completion.complete(const []);
    _pending = null;
    if (_running?.key == key) {
      _running!.wanted = true;
      return _running!.completion.future;
    }
    final task = _SearchTask(key);
    if (_running == null) {
      _running = task;
      unawaited(_drainSearches(task));
    } else {
      _running!.wanted = false;
      _pending = task;
    }
    return task.completion.future;
  }

  Future<void> _drainSearches(_SearchTask task) async {
    while (true) {
      try {
        final query = task.key.query;
        final List<Map<String, dynamic>> results;
        if (_isGvKey(query)) {
          final gv = int.tryParse(query.substring(2));
          results = gv == null ? const [] : [await getPostDetail(gv)];
        } else {
          results = await _searchSelectedSource(task);
        }
        final accepted = !_disposed && task.wanted;
        if (accepted && !_isGvKey(query)) addSearchHistory(query);
        task.completion.complete(accepted ? results : const []);
      } catch (error, stack) {
        if (!_disposed && task.wanted) {
          task.completion.completeError(error, stack);
        } else {
          task.completion.complete(const []);
        }
      }
      final next = _pending;
      _pending = null;
      _running = next;
      if (next == null) return;
      task = next;
    }
  }

  bool _isGvKey(String query) =>
      query.length > gvMinLength && query.startsWith('gv');

  Future<List<Map<String, dynamic>>> _searchSelectedSource(
    _SearchTask task,
  ) async {
    final searchKey = task.key.query;
    final source = task.key.source;
    try {
      if (source == 'bgm') {
        final subjects = await searchBgmSubjects(searchKey);
        if (_disposed || !task.wanted) return const [];
        return List.generate(subjects.length, (index) {
          final subject = subjects[index];
          final cover = BgmUtils.bgmCoverProxyUrl(subject.subjectId);
          return <String, dynamic>{
            'source': 'bgm',
            'title': subject.nameCn?.isNotEmpty == true
                ? subject.nameCn
                : subject.name ?? '未知标题',
            'subtitle':
                subject.nameCn?.isNotEmpty == true &&
                    subject.name?.isNotEmpty == true &&
                    subject.name != subject.nameCn
                ? subject.name
                : subject.summary ?? noDescriptionText,
            'content': cover,
            'bgmImageUrl': cover,
            'bgmId': subject.subjectId,
            '_heroTag': 'bgm_cover_${subject.subjectId}',
            if (subject.score != null) 'score': subject.score,
          };
        });
      }

      if (source.isEmpty) return const [];
      return await _sourceAdapterService.search(
        source,
        searchKey,
        fallbackDescription: noDescriptionText,
        skipBgmEnhancement: AdapterRegistry.isCustomSource(source),
      );
    } catch (error) {
      debugPrint('Search failed for $selectedSourceLabel: $error');
      return const [];
    }
  }

  Future<Map<String, dynamic>?> buildPlayerData(Map<String, dynamic> item) =>
      _sourceAdapterService.buildPlayerData(item);

  List<String> _loadHistory() {
    final historyJson = Instances.sp.getString(_searchHistoryKey);
    if (historyJson == null) return const [];

    try {
      final decoded = jsonDecode(historyJson);
      if (decoded is! List) return const [];
      final history = <String>[];
      final seen = <String>{};
      for (final item in decoded) {
        final value = item.toString().trim();
        if (value.isNotEmpty && seen.add(value)) history.add(value);
        if (history.length == maxHistoryCount) break;
      }
      return history;
    } catch (_) {
      return const [];
    }
  }

  void _persistHistory(List<String> history) {
    if (_disposed) return;
    searchHistoryNotifier.value = history;
    Instances.sp.setString(_searchHistoryKey, jsonEncode(history));
  }

  void addSearchHistory(String value) {
    if (_disposed) return;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    final history = searchHistoryNotifier.value;
    if (history.isNotEmpty && history.first == trimmed) return;

    final next = <String>[trimmed];
    for (final item in history) {
      if (item != trimmed) next.add(item);
      if (next.length >= maxHistoryCount) break;
    }
    _persistHistory(next);
  }

  void removeSearchHistory(String value) {
    if (_disposed) return;
    _persistHistory([
      for (final item in searchHistoryNotifier.value)
        if (item != value) item,
    ]);
  }

  void clearSearchHistory() {
    if (_disposed) return;
    Instances.sp.remove(_searchHistoryKey);
    searchHistoryNotifier.value = const [];
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    invalidateSearch();
    resultsNotifier.value = const [];
    searchHistoryNotifier.value = const [];
    customSources = const [];
    builtinAdapterSources = const [];
    resultsNotifier.dispose();
    selectedSourceIndexNotifier.dispose();
    keywordNotifier.dispose();
    searchHistoryNotifier.dispose();
    showResultsNotifier.dispose();
    isLoadingNotifier.dispose();
    sourceLabelsNotifier.dispose();
    isVerticalLayoutNotifier.dispose();
  }
}

final class _SearchTask {
  _SearchTask(this.key);
  final ({String source, String query, int revision}) key;
  final completion = Completer<List<Map<String, dynamic>>>();
  bool wanted = true;
}
