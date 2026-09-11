import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/api/post.dart';
import 'package:baka/api/request_cache.dart';
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
  final _searchRequests =
      RequestDeduplicator<
        ({int source, String query}),
        List<Map<String, dynamic>>
      >();

  final SourceAdapterService _sourceAdapterService = sourceRepository;
  List<CustomSourceConfig> customSources = [];
  List<AdapterDescriptor> builtinAdapterSources = [];
  Future<void> init({int? initialSource, String? initialKeyword}) async {
    isVerticalLayoutNotifier.value =
        Instances.sp.getBool(_isVerticalLayoutKey) ?? false;
    await reloadCustomSources();
    if (_disposed) return;

    if (initialSource != null) {
      selectedSourceIndexNotifier.value = initialSource;
    }
    searchHistoryNotifier.value = _loadHistory();
    if (initialKeyword != null) keywordNotifier.value = initialKeyword;
  }

  Future<void> reloadCustomSources() async {
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
    activeSearchId++;
    keywordNotifier.value = '';
    showResultsNotifier.value = false;
    resultsNotifier.value = const [];
    isLoadingNotifier.value = false;
  }

  bool isActiveSearch(int searchId) => searchId == activeSearchId;

  Future<List<Map<String, dynamic>>> executeSearch(String searchKey) {
    if (_disposed) return SynchronousFuture(const []);
    final query = searchKey.trim();
    if (query.isEmpty) return SynchronousFuture(const []);

    keywordNotifier.value = query;
    final source = selectedSourceIndexNotifier.value;
    return _searchRequests.run((source: source, query: query), () async {
      if (_isGvKey(query)) {
        final gv = int.tryParse(query.substring(2));
        return gv == null ? const [] : [await getPostDetail(gv)];
      }
      final searchResults = await _searchSelectedSource(query, source);
      if (!_disposed) addSearchHistory(query);
      return searchResults;
    });
  }

  bool _isGvKey(String query) =>
      query.length > gvMinLength && query.startsWith('gv');

  Future<List<Map<String, dynamic>>> _searchSelectedSource(
    String searchKey,
    int source,
  ) async {
    try {
      if (source == 0) {
        final subjects = await searchBgmSubjects(searchKey);
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

      final builtinIndex = source - 1;
      if (builtinIndex >= 0 && builtinIndex < builtinAdapterSources.length) {
        return _sourceAdapterService.search(
          builtinAdapterSources[builtinIndex].key,
          searchKey,
          fallbackDescription: noDescriptionText,
        );
      }

      final customIndex = builtinIndex - builtinAdapterSources.length;
      if (customIndex < 0 || customIndex >= customSources.length) {
        return const [];
      }

      return _sourceAdapterService.search(
        AdapterRegistry.customSourceKey(customSources[customIndex].id),
        searchKey,
        fallbackDescription: noDescriptionText,
        skipBgmEnhancement: true,
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
      return [
        for (final item in decoded)
          if (item.toString().isNotEmpty) item.toString(),
      ];
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

    final next = <String>[trimmed];
    for (final item in searchHistoryNotifier.value) {
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
    activeSearchId++;
    _searchRequests.clear();
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
