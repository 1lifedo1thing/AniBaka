import 'package:baka/source/models/source_search_result.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/utils/json_values.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/models/playback_request.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:baka/source/source_registry.dart';
import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/api/post.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/matching/media_readiness.dart';
import 'package:baka/services/matching/probe_scheduler.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/utils/reg_utils.dart';

final _reAliasSep = RegExp(r'[/／、,，;；\n]');
final _reBrackets = RegExp(r'[（(].*?[）)]');
final _reWhitespace = RegExp(r'\s+');

String _norm(String value) => value.toLowerCase().replaceAll(_reWhitespace, '');

class SearchResultItem {
  SearchResultItem(this.result)
    : matchCandidate = SourceMatchCandidate.fromResult(result);

  final SourceSearchResult result;
  final SourceMatchCandidate matchCandidate;
  String get title => result.title;
  String get sourceType => result.source;
  String get key => result.key;
  String get coverUrl => result.cover;
  String get displayName => result.displayName;
  String get seriesId => result.id;
  late final String? episodeInfo = switch (matchCandidate.episodeCount) {
    final int count when count > 0 => '约 $count 集',
    _ => null,
  };
  late final String? lineInfo = _lineInfo(result.internalData ?? const {});
  late final String? updateInfo = _updateInfo(result.internalData ?? const {});

  static String? _lineInfo(Map data) {
    if (data['videos'] case final String s when s.trim().isNotEmpty) {
      final lines = s
          .split('\n')
          .where((l) => l.trim().isNotEmpty && l.contains('#'))
          .length;
      return lines > 1 ? '包含 $lines 条线路' : null;
    }
    if (data['lineCount'] case final num c when c > 0) {
      return '包含 ${c.toInt()} 条线路';
    }
    return null;
  }

  static String? _updateInfo(Map data) {
    final s = data['time']?.toString().trim() ?? '';
    if (s.isEmpty) {
      return null;
    }
    return BgmUtils.formatTimeString(s, '更新时间');
  }
}

/// 探针状态：
/// - [direct]：目标集媒体已解析并可即点即播（含预取直链 + headers）
/// - [playable]：剧集目录就绪，但媒体地址尚未解析（点选时仍会再取直链）
/// - [failed]：目录或媒体解析失败
enum SourceProbeStatus { pending, resolving, playable, direct, failed }

class SourceProbeState {
  final SearchResultItem item;
  final int episodeIndex;
  final int preferredLine;
  SourceProbeStatus status = SourceProbeStatus.pending;
  PlaybackRequest? data;
  String? routeKey;
  int? resolvedLineIndex;
  String? error;
  String? mediaUrl;
  Future<SourceProbeState>? future;

  SourceProbeState({
    required this.item,
    required this.episodeIndex,
    required this.preferredLine,
  });

  /// 目录就绪即可选；[direct] 额外保证已预取可播媒体。
  bool get isReady =>
      status == SourceProbeStatus.playable ||
      status == SourceProbeStatus.direct;

  /// 已具备即点即播条件。
  bool get isInstantPlayable => status == SourceProbeStatus.direct;
}

class SourceCandidateState {
  final SearchResultItem item;
  final int score;
  final SourceProbeState probe;

  const SourceCandidateState({
    required this.item,
    required this.score,
    required this.probe,
  });

  SourceProbeStatus get status => probe.status;
  bool get isReady => probe.isReady;
  bool get isInstantPlayable => probe.isInstantPlayable;
}

class DirectSourceGroup {
  const DirectSourceGroup({
    required this.key,
    required this.origins,
    required this.status,
  });

  final String key;
  final List<SourceCandidateState> origins;
  final SourceProbeStatus status;

  SourceCandidateState get primary => origins.first;
  bool get isReady => primary.isReady;
  bool get isInstantPlayable => primary.isInstantPlayable;
}

/// 视频源搜索与切换逻辑控制器
class VideoSourceSearchController extends ChangeNotifier {
  static VideoSourceSearchController? globalCached;
  static String? globalCachedTitle;

  static void cacheGlobal(
    String title,
    VideoSourceSearchController controller,
  ) {
    if (!identical(globalCached, controller)) globalCached?.dispose();
    globalCached = controller;
    globalCachedTitle = title;
  }

  static bool isGlobalCached(VideoSourceSearchController controller) =>
      identical(globalCached, controller);

  /// The global slot only transfers a completed search from detail to player.
  /// Once consumed, the player owns and disposes the controller.
  static VideoSourceSearchController takeSharedFor({
    Map<String, dynamic>? seedData,
    String? title,
  }) {
    return takeCachedFor(seedData: seedData, title: title) ??
        VideoSourceSearchController(
          seedData: seedData,
          title: resolveTitle(title: title, seedData: seedData),
        );
  }

  static VideoSourceSearchController? takeCachedFor({
    Map<String, dynamic>? seedData,
    String? title,
  }) {
    final resolved = resolveTitle(title: title, seedData: seedData);
    final cached = globalCached;
    if (cached != null && globalCachedTitle == resolved) {
      globalCached = null;
      globalCachedTitle = null;
      return cached;
    }
    cached?.dispose();
    globalCached = null;
    globalCachedTitle = null;
    return null;
  }

  static String resolveTitle({String? title, Map<String, dynamic>? seedData}) {
    final explicit = title?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return seedData?['title']?.toString().trim() ?? '';
  }

  final String title;
  final Map<String, dynamic>? seedData;
  final bool autoMatchMode;
  final int targetEpisodeIndex;
  final ValueChanged<PlaybackRequest>? onMatchFound;
  final VoidCallback? onMatchFailed;

  bool isSearching = false;
  List<String> manualAliases = const [];
  late final List<String> automaticAliases;
  final Set<String> activeAutoAliases = {};

  Iterable<SearchResultItem> get results => _results.values;
  int resultCountFor(String source) => _sourceCounts[source] ?? 0;
  Set<String> get progressingSources => _progressing;
  Set<String> get finishedSources => _finished;
  List<String> get searchErrors => _errors;

  final _adapter = sourceRepository;
  final _engine = const SourceMatchEngine();
  Future<void>? _adapterInitFuture;

  Future<void> ensureAdapterReady() => _adapterInitFuture ??= _adapter
      .init()
      .catchError((Object error, StackTrace stack) {
        _adapterInitFuture = null;
        Error.throwWithStackTrace(error, stack);
      });

  final _results = <String, SearchResultItem>{};
  final _sourceCounts = <String, int>{};
  final _errors = <String>[];
  final _finished = <String>{};
  final _progressing = <String>{};

  /// 已解析的完整播放数据（含在途请求去重）；有界 LRU，避免长时间搜索堆积。
  final _resolved = RequestCache<String, PlaybackRequest>(limit: 32);
  final _probes = <String, SourceProbeState>{};
  final _rankCache = <String, SourceMatchScore>{};
  final _rejectedKeys = <String>{};
  SourceMatchContext? _matchContext;
  (SourceMatchContext, int, int, int, String?)? _switchKey;
  List<SourceCandidateState> _switchCandidates = const [];
  final _autoProbesBySource = <String, int>{};
  final _prefetched = <String>{};
  int _autoProbesTotal = 0;
  int _autoRunId = 0;
  Timer? _deadlineTimer;
  late final ProbeScheduler<SearchResultItem> _probeScheduler;
  DateTime? _autoMatchStartedAt;
  Completer<bool>? _autoMatchGate;
  Set<Future<void>> _autoWork = {};

  /// 最近一次自动匹配耗时（认领或失败），供调试/对比。
  Duration? lastAutoMatchDuration;

  /// 目录解析的软超时（buildPlaybackRequest）— 竞速档。
  static const Duration _catalogTimeout = Duration(milliseconds: 2000);

  /// 单条线路：解析直链 + 可达性校验 — 竞速档（快失败）。
  static const Duration _mediaTimeout = Duration(milliseconds: 2800);

  /// 单候选总预算：目录 + 一次媒体解析。
  static const Duration _candidateBudget = SourceMatchEngine.candidateBudget;

  /// 手动点选时稍放宽。
  static const Duration _manualMediaTimeout = Duration(milliseconds: 5500);

  /// 记忆命中总超时。
  static const Duration _memoryTimeout = Duration(milliseconds: 3500);

  /// 绝对上限：到时无论是否命中都要给出结论，避免慢源拖尾。
  static const Duration _autoMatchHardDeadline = SourceMatchEngine.hardDeadline;

  /// 单个源搜索上限，避免某个无响应源让完整搜索永远无法收尾。
  static const Duration _autoSourceSearchBudget =
      SourceMatchEngine.sourceSearchBudget;

  /// 自动匹配并发：同时按「手动点选」路径处理的候选数。
  static const int _autoProbeConcurrency = SourceMatchEngine.raceConcurrency;

  /// 自动匹配每候选最多线路。
  static const int _autoMatchMaxLines = SourceMatchEngine.maxLinesPerCandidate;

  /// 手动点选最多尝试线路。
  static const int _manualMaxLines = 4;

  /// 手动搜索后台预解析的候选总数上限。
  static const int _maxPrefetch = 3;

  /// 可达性探测超时。
  static const Duration _reachTimeout = Duration(milliseconds: 1500);

  late final String _primary;
  late final String _aliasKey;
  int _runId = 0;
  SourceOperation _sourceOperation = SourceOperation();
  bool _disposed = false;
  bool _userSelected = false;
  bool _autoMatched = false;

  void markUserSelected() => _userSelected = true;
  bool get isDisposed => _disposed;
  bool get hasMatched => _autoMatched;

  VideoSourceSearchController({
    this.seedData,
    String? title,
    this.autoMatchMode = false,
    this.targetEpisodeIndex = 0,
    this.onMatchFound,
    this.onMatchFailed,
  }) : title = resolveTitle(title: title, seedData: seedData) {
    _primary = this.title;
    _aliasKey = switch (seedData?['bgmId']?.toString().trim()) {
      final String id when id.isNotEmpty => 'bgm:$id',
      _ => 'title:${_norm(this.title)}',
    };
    manualAliases = _readManualAliases();
    automaticAliases = _buildAutoAliases();
    _probeScheduler = ProbeScheduler<SearchResultItem>(
      concurrency: _autoProbeConcurrency,
      keyOf: _probeKey,
      run: _runAutoProbe,
    );
  }

  /// 探针唯一键：同一候选在同一集/线路只探一次。
  String _probeKey(SearchResultItem item) => '${item.key}|$_ep|1';

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(globalCached, this)) {
      globalCached = null;
      globalCachedTitle = null;
    }
    _sourceOperation.cancel();
    _sourceOperation.close();
    _runId++;
    _cancelAutoTimers();
    _probeScheduler.close();
    _completeAutoMatchGate(false);
    _autoWork.clear();
    // 释放已解析的候选 / 播放数据；控制器在播放器侧仍被引用，但不再需要它们。
    _releaseRetainedData();
    super.dispose();
  }

  /// 清空一次搜索会话的全部派生数据。
  void _releaseRetainedData() {
    _switchKey = null;
    _switchCandidates = const [];
    _results.clear();
    _sourceCounts.clear();
    _errors.clear();
    _finished.clear();
    _progressing.clear();
    _resolved.clear();
    _probes.clear();
    _rankCache.clear();
    _rejectedKeys.clear();
    _matchContext = null;
    _autoProbesBySource.clear();
    _autoProbesTotal = 0;
    _prefetched.clear();
  }

  List<String> _buildAutoAliases() {
    final pool = <String>{_primary};
    final detail = asMap(seedData?['bgmDetailData']);
    if (detail != null) {
      for (final raw in [detail['name_cn'], detail['name']]) {
        if (raw != null) {
          pool.addAll(
            raw
                .toString()
                .split(_reAliasSep)
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty),
          );
        }
      }
    }
    final out = <String>[];
    final seen = {_norm(_primary)};
    for (final c in pool) {
      final clean = c
          .replaceAll(_reBrackets, '')
          .replaceAll(_reWhitespace, ' ')
          .trim();
      final base = RegUtils.extractBaseTitle(c);
      for (final candidate in [c, clean, base]) {
        if (candidate.isNotEmpty && seen.add(_norm(candidate))) {
          out.add(candidate);
          if (out.length >= 6) return out;
        }
      }
    }
    return out;
  }

  List<String> _readManualAliases() {
    final raw = MatchMemoryService.readAliases(
      _aliasKey,
      fallbackKey: 'title:${_norm(title)}',
    );
    final seen = {_norm(_primary)};
    return [
      for (final item in raw)
        if (item.trim() case final String a
            when a.isNotEmpty && seen.add(_norm(a)))
          a,
    ];
  }

  Future<void> toggleAutoAlias(String alias) async {
    if (_disposed || isSearching) return;
    if (!activeAutoAliases.remove(alias)) {
      activeAutoAliases.add(alias);
    }
    notifyListeners();
    await startSearch();
  }

  Future<bool> addManualAlias(String value) async {
    if (_disposed || isSearching) return false;
    List<String>? next;
    final seen = {_norm(_primary), for (final a in manualAliases) _norm(a)};
    for (final part in value.split(_reAliasSep)) {
      final alias = part.trim();
      if (alias.isNotEmpty && seen.add(_norm(alias))) {
        (next ??= List.of(manualAliases)).add(alias);
      }
    }
    if (next == null) return false;
    manualAliases = next;
    final runId = _runId;
    notifyListeners();
    await MatchMemoryService.saveAliases(_aliasKey, next);
    if (_alive(runId)) await startSearch();
    return true;
  }

  Future<void> removeManualAlias(String alias) async {
    if (_disposed || isSearching) return;
    final normalized = _norm(alias);
    manualAliases = manualAliases.where((a) => _norm(a) != normalized).toList();
    final runId = _runId;
    notifyListeners();
    await MatchMemoryService.saveAliases(_aliasKey, manualAliases);
    if (_alive(runId)) await startSearch();
  }

  Future<void> startSearch() async {
    if (_disposed) return;
    _cancelAutoTimers();
    _completeAutoMatchGate(false);
    _sourceOperation.cancel();
    _sourceOperation.close();
    _sourceOperation = SourceOperation();
    final runId = ++_runId;
    _autoRunId = runId;
    final operation = _sourceOperation;
    _autoWork = {};
    _autoMatched = false;
    lastAutoMatchDuration = null;
    _autoMatchStartedAt = autoMatchMode ? DateTime.now() : null;
    final gate = autoMatchMode ? Completer<bool>() : null;
    _autoMatchGate = gate;
    _releaseRetainedData();
    _probeScheduler.reset();
    isSearching = true;
    _emitProgress();

    try {
      await operation.wait(ensureAdapterReady());
    } catch (_) {
      if (!_alive(runId) || operation.isCancelled) return;
      _errors.add('搜索初始化失败');
      _stopBackgroundWork();
      _completeAutoMatchGate(false);
      isSearching = false;
      _emitProgress();
      if (_alive(runId) && autoMatchMode && !_userSelected) {
        _recordAutoMatchDuration();
        onMatchFailed?.call();
      }
      return;
    }
    if (!_alive(runId)) return;

    final memoryFuture = autoMatchMode ? _tryMemory(runId) : null;
    final sources = [
      for (final source in sourceCatalog.quickSearchSources)
        (key: source.key, error: '${source.displayName} 搜索失败'),
      for (final source in sourceCatalog.enabledCustomSources)
        (
          key: AdapterRegistry.customSourceKey(source.id),
          error: '${source.name} 搜索失败',
        ),
      // 站内源只用于手动列表，不参与自动匹配。
      if (!autoMatchMode) (key: 'internal', error: '站内搜索失败'),
    ];

    // 自动匹配只搜主标题：最快的路径，别名回退已移除。
    final keywords = autoMatchMode
        ? <String>[_primary]
        : <String>[
            _primary,
            ...manualAliases.take(3),
            ...automaticAliases.where(activeAutoAliases.contains).take(3),
          ];

    final keywordPlan = SourceMatchEngine.planKeywords(
      autoMatch: autoMatchMode,
      titles: keywords,
    );
    _progressing.addAll(sources.map((source) => source.key));

    final tasks = [
      for (final source in sources)
        () => _searchSource(
          runId: runId,
          operation: operation,
          keywordPlan: keywordPlan,
          sourceKey: source.key,
          errorMsg: source.error,
        ),
    ];

    // 自动匹配更高搜索并发，尽快产出首条高置信结果。
    final searchFuture = _runPool(
      tasks,
      autoMatchMode ? SourceMatchEngine.autoSearchConcurrency : 8,
      shouldStop: () =>
          operation.isCancelled ||
          _autoMatched ||
          !_alive(runId) ||
          _autoMatchSettled,
    );

    if (!autoMatchMode) {
      await searchFuture;
      if (!_alive(runId)) return;
      isSearching = false;
      _emitProgress();
      return;
    }

    _startAutoTimers(runId);
    unawaited(
      _driveAutoMatch(
        runId,
        operation,
        gate!,
        searchFuture,
        memoryFuture,
      ).catchError((Object error, StackTrace _) {
        if (kDebugMode) debugPrint('[AutoMatch] aborted: $error');
        _completeGate(gate, false);
      }),
    );

    // gate 必在「认领 / 全源结束 / 硬截止」三者之一完成，不再傻等慢源。
    await gate.future;
    if (!_alive(runId)) return;
    isSearching = false;
    _emitProgress();
    if (_alive(runId) && !_autoMatched && !_userSelected) {
      _recordAutoMatchDuration();
      onMatchFailed?.call();
    }
  }

  void _startAutoTimers(int runId) {
    _cancelAutoTimers();
    // 硬截止：停止后续探针并给出结论。这是自动匹配唯一的兜底计时器，
    // 结果一到就探（first-ready）之外不再有任何补探轮次。
    _deadlineTimer = Timer(_autoMatchHardDeadline, () {
      if (!_alive(runId) || _autoMatched || _userSelected) {
        _completeGate(_autoMatchGate, _autoMatched);
        return;
      }
      _stopBackgroundWork();
      _completeAutoMatchGate(false);
    });
  }

  bool get _autoMatchSettled {
    final gate = _autoMatchGate;
    return gate != null && gate.isCompleted;
  }

  void _cancelAutoTimers() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
  }

  Future<void> _driveAutoMatch(
    int runId,
    SourceOperation operation,
    Completer<bool> gate,
    Future<void> searchFuture,
    Future<bool>? memoryFuture,
  ) async {
    if (memoryFuture != null && await memoryFuture) {
      // 记忆命中：_tryMemory 已认领并关闭探针调度。
      unawaited(searchFuture);
      _completeGate(gate, true);
      return;
    }
    if (!_alive(runId)) return;
    if (_autoMatched || _userSelected) {
      _completeGate(gate, _autoMatched);
      return;
    }

    final work = _autoWork;
    try {
      await operation.wait(searchFuture);
      await operation.wait(_probeScheduler.drained);
      // A soft timeout releases a probe slot, but its media can still win.
      // Include the raw work and late-result adoption before declaring failure.
      while (work.isNotEmpty && _alive(runId) && !gate.isCompleted) {
        await operation.wait(Future.wait(List.of(work)));
      }
      if (_alive(runId) && !gate.isCompleted) {
        _stopBackgroundWork();
        _completeGate(gate, _autoMatched);
      }
    } catch (_) {
      if (!operation.isCancelled) rethrow;
    }
  }

  Future<T> _trackAutoWork<T>(Future<T> future) {
    if (!autoMatchMode) return future;
    final work = _autoWork;
    late final Future<void> settled;
    settled = future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => work.remove(settled));
    work.add(settled);
    return future;
  }

  void _completeGate(Completer<bool>? gate, bool matched) {
    if (gate != null && !gate.isCompleted) gate.complete(matched);
  }

  void _completeAutoMatchGate(bool matched) =>
      _completeGate(_autoMatchGate, matched);

  void _recordAutoMatchDuration() {
    final started = _autoMatchStartedAt;
    if (started == null) return;
    lastAutoMatchDuration = DateTime.now().difference(started);
    if (kDebugMode) {
      debugPrint(
        '[AutoMatch] done matched=$_autoMatched '
        'in ${lastAutoMatchDuration!.inMilliseconds}ms',
      );
    }
  }

  Future<bool> _tryMemory(int runId) async {
    final bgmId = toInt(seedData?['bgmId']);
    final memory = MatchMemoryService.read(bgmId: bgmId, title: _primary);
    if (memory == null) return false;

    final item = SearchResultItem(
      SourceSearchResult(
        Series(
          memory.seriesId,
          memory.title?.isNotEmpty == true ? memory.title! : _primary,
        ),
        source: memory.source,
        displayName: memory.sourceDisplayName ?? memory.source,
      ),
    );

    try {
      // 记忆命中必须完整解析到可播媒体，避免「匹配成功却播不了」。
      final probe = await ensureCandidatePlayable(
        item,
        episodeIndex: _ep,
        preferredLine: 1,
        resolveMedia: true,
        raceMode: true,
      ).timeout(_memoryTimeout);
      if (!_alive(runId) || _autoMatched || _userSelected) return true;
      if (probe.isInstantPlayable && probe.data != null) {
        return _claimAutoMatch(runId, item, probe.data!);
      }
    } catch (_) {}

    if (!_alive(runId) || _autoMatched || _userSelected || _autoMatchSettled) {
      return false;
    }
    try {
      await MatchMemoryService.remove(bgmId: bgmId, title: _primary);
    } catch (_) {}
    return false;
  }

  /// 原子认领自动匹配结果；成功后停止后续搜索/探针。
  bool _claimAutoMatch(int runId, SearchResultItem item, PlaybackRequest data) {
    if (!_alive(runId) || _autoMatched || _userSelected) return false;
    if (_autoMatchSettled) return false;
    final gate = _autoMatchGate;
    _autoMatched = true;
    _stopBackgroundWork();
    _recordAutoMatchDuration();
    _completeGate(gate, true);
    onMatchFound?.call(data.copyWith());
    unawaited(persistMatchMemory(item, data));
    return true;
  }

  void cancelSearch() {
    _runId++;
    _stopBackgroundWork();
    _completeAutoMatchGate(false);
    if (!_disposed) {
      isSearching = false;
      _progressing.clear();
      _emitProgress();
    }
  }

  void _stopBackgroundWork() {
    _sourceOperation.cancel();
    _sourceOperation.close();
    _sourceOperation = SourceOperation();
    _cancelAutoTimers();
    _probeScheduler.close();
    _progressing.clear();
    for (final probe in _probes.values) {
      if (probe.future == null && probe.status != SourceProbeStatus.resolving) {
        continue;
      }
      probe.future = null;
      if (probe.isInstantPlayable) continue;
      if (probe.data == null) _resolved.remove(probe.item.key);
      probe.status = probe.data == null
          ? SourceProbeStatus.pending
          : SourceProbeStatus.playable;
    }
  }

  Future<void> _runPool(
    List<Future<void> Function()> tasks,
    int concurrency, {
    bool Function()? shouldStop,
  }) async {
    var next = 0;
    Future<void> worker() async {
      while (next < tasks.length) {
        if (shouldStop?.call() ?? false) return;
        final i = next++;
        await tasks[i]();
      }
    }

    final n = tasks.length < concurrency ? tasks.length : concurrency;
    if (n > 0) {
      await Future.wait(List.generate(n, (_) => worker()));
    }
  }

  bool _alive(int runId) => !_disposed && runId == _runId;

  void _emitProgress() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _searchSource({
    required int runId,
    required SourceOperation operation,
    required SourceKeywordPlan keywordPlan,
    required String sourceKey,
    required String errorMsg,
  }) async {
    if (keywordPlan.isEmpty) {
      return _finishSource(runId, sourceKey);
    }
    var attempted = 0;
    var failed = 0;
    var found = false;

    Future<List<SourceSearchResult>?> tryKeyword(String kw) async {
      final search = SourceOperation(
        parent: operation,
        timeout: autoMatchMode ? _autoSourceSearchBudget : null,
      );
      try {
        return await search.run(
          () => sourceKey == 'internal'
              ? _loadInternal(kw)
              : _adapter.search(sourceKey, kw, skipBgmEnhancement: true),
        );
      } catch (_) {
        return null;
      } finally {
        search.cancel();
        search.close();
      }
    }

    final raceKws = keywordPlan.race;
    final extraKeywords = keywordPlan.fallback;

    if (raceKws.isNotEmpty) {
      attempted += raceKws.length;
      final hit = await _raceKeywords(raceKws, tryKeyword, runId);
      if (!_alive(runId) || operation.isCancelled || _autoMatched) return;
      if (hit == null) {
        failed += raceKws.length;
      } else {
        if (hit.isNotEmpty) {
          found = true;
          _appendResults(runId, sourceKey, hit);
        } else {
          failed++;
        }
      }
    }

    if (!found &&
        !_autoMatched &&
        !_autoMatchSettled &&
        _alive(runId) &&
        extraKeywords.isNotEmpty) {
      for (final kw in extraKeywords) {
        if (!_alive(runId) || _autoMatched || _autoMatchSettled) return;
        if (_results.length >= 8) break;
        attempted++;

        final raw = await tryKeyword(kw);
        if (!_alive(runId) || _autoMatched) return;
        if (raw == null) {
          failed++;
          continue;
        }

        if (raw.isNotEmpty) {
          found = true;
          _appendResults(runId, sourceKey, raw);
          break;
        }
      }
    }

    _finishSource(
      runId,
      sourceKey,
      error: attempted > 0 && failed == attempted && !found ? errorMsg : null,
    );
  }

  Future<List<SourceSearchResult>?> _raceKeywords(
    List<String> keywords,
    Future<List<SourceSearchResult>?> Function(String) load,
    int runId,
  ) async {
    if (keywords.length == 1) {
      final raw = await load(keywords.first);
      if (raw == null || raw.isEmpty) return null;
      return raw;
    }

    final done = Completer<List<SourceSearchResult>?>();
    var remaining = keywords.length;

    for (final kw in keywords) {
      unawaited(() async {
        final raw = await load(kw);
        if (!_alive(runId) || _autoMatched) {
          if (!done.isCompleted) done.complete(null);
          return;
        }
        if (raw != null && raw.isNotEmpty) {
          if (!done.isCompleted) {
            done.complete(raw);
          }
          return;
        }
        remaining--;
        if (remaining <= 0 && !done.isCompleted) {
          done.complete(null);
        }
      }());
    }

    return done.future;
  }

  Future<List<SourceSearchResult>> _loadInternal(String keyword) async {
    final raw = await getSearch(keyword);
    return [
      for (final item in raw)
        if (item['videos'] != null) SourceSearchResult.internal(item),
    ];
  }

  void _appendResults(
    int runId,
    String source,
    Iterable<SourceSearchResult> rows,
  ) {
    if (!_alive(runId)) return;
    final context = _syncContext();
    var accepted = 0;
    final freshHigh = <SearchResultItem>[];

    for (final data in rows) {
      if (_results.length >= 100) break;
      final count = _sourceCounts[source] ?? 0;
      if (count >= 20) break;
      final key = data.key;
      if (_results.containsKey(key) || _rejectedKeys.contains(key)) continue;
      final item = SearchResultItem(data);

      if (item.sourceType != 'internal') {
        final score = _engine.score(item.matchCandidate, context);
        if (score.confidence < SourceMatchEngine.admissionConfidence) {
          _rejectedKeys.add(key);
          continue;
        }
        _rankCache[key] = score;
        if (autoMatchMode && score.shouldProbeImmediately) freshHigh.add(item);
      }

      _results[item.key] = item;
      _sourceCounts[item.sourceType] = count + 1;
      accepted++;
    }
    if (accepted == 0) return;

    if (!_disposed) notifyListeners();

    if (autoMatchMode && !_userSelected && !_autoMatched) {
      freshHigh.sort((a, b) {
        final sa = _rankCache[a.key]?.confidence ?? 0;
        final sb = _rankCache[b.key]?.confidence ?? 0;
        return sb.compareTo(sa);
      });
      for (final item in freshHigh) {
        _enqueueAutoProbe(runId, item);
      }
    } else if (!autoMatchMode) {
      // 手动搜索：后台预解析前几名，点选时尽量零等待。
      _prefetchTopCandidates();
    }
  }

  /// 手动搜索：后台预解析前几名，点选时尽量零等待。
  ///
  /// 每次有源返回结果都会重排前几名；若不加约束，会随着结果累积不断对新的
  /// 候选发起「目录 + 媒体」解析，白白占用带宽与连接。这里全局只预取固定
  /// 名额，且同一候选只预取一次。
  void _prefetchTopCandidates() {
    if (_prefetched.length >= _maxPrefetch) return;
    for (final s in _bestTwo(_syncContext())) {
      if (_prefetched.length >= _maxPrefetch) return;
      final item = _results[s.candidate.key];
      if (item == null || !_prefetched.add(item.key)) continue;
      unawaited(
        ensureCandidatePlayable(
          item,
          episodeIndex: _ep,
          preferredLine: 1,
          resolveMedia: true,
        ).then<void>((_) {}, onError: (Object _) {}),
      );
    }
  }

  List<SourceMatchScore> _bestTwo(SourceMatchContext context) {
    SourceMatchScore? first;
    SourceMatchScore? second;
    for (final item in _results.values) {
      if (item.sourceType == 'internal') continue;
      final score = _rankCache[item.key] ??= _engine.score(
        item.matchCandidate,
        context,
      );
      if (!score.shouldProbeImmediately) continue;
      if (first == null || SourceMatchEngine.compareScores(score, first) < 0) {
        second = first;
        first = score;
      } else if (second == null ||
          SourceMatchEngine.compareScores(score, second) < 0) {
        second = score;
      }
    }
    // Equal scores retain arrival order; List.sort did not define a tie order.
    return [?first, ?second];
  }

  void _finishSource(int runId, String sourceKey, {String? error}) {
    if (!_alive(runId)) return;
    if (error != null) _errors.add(error);
    _progressing.remove(sourceKey);
    _finished.add(sourceKey);
    _emitProgress();
  }

  void _enqueueAutoProbe(int runId, SearchResultItem item) {
    if (!_alive(runId) || _autoMatched || _userSelected) return;
    if (_autoMatchSettled || _probeScheduler.isClosed) return;
    if (item.sourceType == 'internal') return;
    if (_autoProbesTotal >= SourceMatchEngine.maxAutoProbes) return;

    final used = _autoProbesBySource[item.sourceType] ?? 0;
    if (used >= SourceMatchEngine.raceProbesPerSource) return;

    final score = _rankCache[item.key];
    if (score != null && !score.shouldProbeImmediately) return;

    if (!_probeScheduler.add(item)) return;
    _autoProbesBySource[item.sourceType] = used + 1;
    _autoProbesTotal++;
  }

  Future<void> _runAutoProbe(SearchResultItem item) async {
    final runId = _autoRunId;
    if (_disposed || !_alive(runId) || _autoMatched || _userSelected) return;
    if (_autoMatchSettled) return;
    try {
      final probe = await _trackAutoWork(
        ensureCandidatePlayable(
          item,
          episodeIndex: _ep,
          preferredLine: 1,
          resolveMedia: true,
          raceMode: true,
        ),
      ).timeout(_candidateBudget);
      if (!_alive(runId) || _userSelected || _autoMatched) return;
      if (probe.isInstantPlayable && probe.data != null) {
        _claimAutoMatch(runId, item, probe.data!);
      }
    } catch (_) {}
  }

  Future<PlaybackRequest?> findNextPlayableCandidate({
    required Set<String> excludedKeys,
    int? episodeIndex,
  }) async {
    final ep = episodeIndex ?? _ep;
    final context = _syncContext();

    final ranked = [
      for (final item in _results.values)
        if (item.sourceType != 'internal' &&
            !excludedKeys.contains(item.key) &&
            !excludedKeys.contains(item.sourceType))
          _rankCache[item.key] ??= _engine.score(item.matchCandidate, context),
    ]..sort(SourceMatchEngine.compareScores);

    for (final rankedItem in ranked) {
      final item = _results[rankedItem.candidate.key];
      if (item == null) continue;
      try {
        final probe = await ensureCandidatePlayable(
          item,
          episodeIndex: ep,
          preferredLine: 1,
          resolveMedia: true,
          raceMode: true,
        ).timeout(_candidateBudget);
        if (probe.isInstantPlayable && probe.data != null) {
          unawaited(persistMatchMemory(item, probe.data!));
          return probe.data!;
        }
      } catch (_) {}
    }
    return null;
  }

  int get _ep => targetEpisodeIndex < 0 ? 0 : targetEpisodeIndex;

  SourceMatchContext _syncContext() {
    final detail = asMap(seedData?['bgmDetailData']);
    final declared = toInt(
      detail?['eps'] ?? detail?['total_episodes'] ?? detail?['totalEpisodes'],
    );
    final episodes = detail?['episodes'];
    final loaded = episodes is List
        ? episodes.where((e) => e is Map && (toInt(e['type']) ?? 0) == 0).length
        : 0;
    final count = declared ?? (loaded > 0 ? loaded : null);
    final completed = declared != null && loaded >= declared;
    final cached = _matchContext;
    if (cached != null &&
        cached.primaryTitle == _primary &&
        listEquals(cached.manualAliases, manualAliases) &&
        listEquals(cached.automaticAliases, automaticAliases) &&
        cached.bgmEpisodeCount == count &&
        cached.bgmCompleted == completed) {
      return cached;
    }
    _rankCache.clear();
    _rejectedKeys.clear();
    return _matchContext = SourceMatchContext(
      primaryTitle: _primary,
      manualAliases: List.of(manualAliases),
      automaticAliases: List.of(automaticAliases),
      bgmEpisodeCount: count,
      bgmCompleted: completed,
    );
  }

  Future<void> persistMatchMemory(SearchResultItem item, PlaybackRequest data) {
    return MatchMemoryService.writeSuccess(
      bgmId: toInt(seedData?['bgmId'] ?? data.metadata['bgmId']),
      title: _primary,
      source: item.sourceType,
      seriesId: item.seriesId,
      candidateTitle: item.title,
      sourceDisplayName: item.displayName,
    );
  }

  List<DirectSourceGroup> getDirectSourceGroups({
    required int episodeIndex,
    required int preferredLine,
    String? currentSource,
  }) {
    if (_disposed) return const [];
    final context = _syncContext();
    final key = (
      context,
      episodeIndex,
      preferredLine,
      _results.length,
      currentSource,
    );
    if (_switchKey != key) {
      _switchKey = key;
      _switchCandidates =
          [
            for (final item in _results.values)
              SourceCandidateState(
                item: item,
                score: (_rankCache[item.key] ??= _engine.score(
                  item.matchCandidate,
                  context,
                )).forCurrentSource(currentSource).score,
                probe: _probeFor(item, episodeIndex, preferredLine),
              ),
          ]..sort((a, b) {
            final score = b.score.compareTo(a.score);
            return score != 0 ? score : a.item.key.compareTo(b.item.key);
          });
    }
    // 匹配分只在候选/上下文变化时排序；探针更新按五种状态线性分桶。
    final buckets = List.generate(5, (_) => <SourceCandidateState>[]);
    for (final candidate in _switchCandidates) {
      buckets[_statusRank(candidate.status)].add(candidate);
    }
    final grouped = <String, List<SourceCandidateState>>{};
    for (final c in buckets.expand((bucket) => bucket)) {
      final key = c.probe.routeKey ?? 'candidate:${c.item.key}';
      (grouped[key] ??= []).add(c);
    }
    return [
      for (final e in grouped.entries)
        DirectSourceGroup(
          key: e.key,
          origins: e.value,
          status: e.value.first.status,
        ),
    ];
  }

  void startSwitchProbes(Iterable<SourceCandidateState> candidates) {
    var active = candidates
        .where((c) => c.status == SourceProbeStatus.resolving)
        .length;
    if (active >= 4) return;
    for (final c in candidates) {
      if (c.status == SourceProbeStatus.pending ||
          c.status == SourceProbeStatus.playable) {
        unawaited(
          ensureCandidatePlayable(
            c.item,
            episodeIndex: c.probe.episodeIndex,
            preferredLine: c.probe.preferredLine,
            resolveMedia: true,
          ).then<void>((_) {}, onError: (Object _) {}),
        );
        if (++active >= 4) {
          return;
        }
      }
    }
  }

  Future<SourceProbeState> resolveSwitchCandidate(
    SourceCandidateState candidate,
  ) {
    final probe = candidate.probe;
    if (probe.isInstantPlayable) {
      return _sourceOperation.wait(Future.value(probe));
    }
    return ensureCandidatePlayable(
      candidate.item,
      episodeIndex: probe.episodeIndex,
      preferredLine: probe.preferredLine,
      resolveMedia: true,
    );
  }

  /// 用户点选条目：完整解析到可播媒体后返回 data，供即点即播。
  Future<PlaybackRequest?> prepareForPlayback(
    SearchResultItem item, {
    int? episodeIndex,
    int preferredLine = 1,
  }) async {
    final probe = await ensureCandidatePlayable(
      item,
      episodeIndex: episodeIndex ?? _ep,
      preferredLine: preferredLine,
      resolveMedia: true,
      raceMode: false,
    );
    return probe.isReady ? probe.data : null;
  }

  int _statusRank(SourceProbeStatus s) => switch (s) {
    SourceProbeStatus.direct => 0,
    SourceProbeStatus.playable => 1,
    SourceProbeStatus.resolving => 2,
    SourceProbeStatus.pending => 3,
    SourceProbeStatus.failed => 4,
  };

  /// [resolveMedia]：是否继续把目标集解析成真实播放地址并写入预取。
  /// [raceMode]：自动匹配竞速——更短超时、少扫线、解析失败不重试。
  Future<SourceProbeState> ensureCandidatePlayable(
    SearchResultItem item, {
    required int episodeIndex,
    required int preferredLine,
    bool resolveMedia = true,
    bool raceMode = false,
  }) => _sourceOperation.run(
    () => _ensureCandidatePlayable(
      item,
      episodeIndex: episodeIndex,
      preferredLine: preferredLine,
      resolveMedia: resolveMedia,
      raceMode: raceMode,
    ),
  );

  Future<SourceProbeState> _ensureCandidatePlayable(
    SearchResultItem item, {
    required int episodeIndex,
    required int preferredLine,
    bool resolveMedia = true,
    bool raceMode = false,
  }) {
    final probe = _probeFor(item, episodeIndex, preferredLine);
    if (probe.isInstantPlayable || (!resolveMedia && probe.isReady)) {
      return Future.value(probe);
    }
    final running = probe.future;
    if (running != null) {
      if (!resolveMedia || probe.status == SourceProbeStatus.playable) {
        return running;
      }
      return running.then((state) {
        SourceOperation.check();
        if (state.isInstantPlayable ||
            state.status == SourceProbeStatus.failed ||
            state.data == null) {
          return state;
        }
        // 目录请求先完成，再复用其数据升级媒体；共享同一在途探针。
        return state.future ??
            _ensureCandidatePlayable(
              item,
              episodeIndex: episodeIndex,
              preferredLine: preferredLine,
              raceMode: raceMode,
            );
      });
    }

    final future = _resolveProbe(
      probe,
      resolveMedia: resolveMedia,
      raceMode: raceMode,
    );
    probe.future = future;
    void clear() {
      if (identical(probe.future, future)) probe.future = null;
    }

    unawaited(
      future.then<void>((_) => clear(), onError: (Object _) => clear()),
    );
    return future;
  }

  SourceProbeState _probeFor(
    SearchResultItem item,
    int episodeIndex,
    int preferredLine,
  ) {
    final key = '${item.key}|$episodeIndex|$preferredLine';
    return _probes.putIfAbsent(
      key,
      () => SourceProbeState(
        item: item,
        episodeIndex: episodeIndex,
        preferredLine: preferredLine,
      ),
    );
  }

  Future<SourceProbeState> _resolveProbe(
    SourceProbeState probe, {
    required bool resolveMedia,
    bool raceMode = false,
  }) async {
    probe.status = SourceProbeStatus.resolving;
    _emitProgress();

    try {
      final catalogTimeout = raceMode
          ? _catalogTimeout
          : const Duration(milliseconds: 4000);
      final videoData =
          probe.data ??
          await resolveVideoData(probe.item).timeout(catalogTimeout);
      SourceOperation.check();
      final rawEpisodes = videoData.episodes;

      if (rawEpisodes.isEmpty) {
        probe.status = SourceProbeStatus.failed;
        probe.error = '未找到可播放剧集';
        _emitProgress();
        return probe;
      }

      final epIndex =
          (probe.episodeIndex >= 0 && probe.episodeIndex < rawEpisodes.length)
          ? probe.episodeIndex
          : 0;
      final episodeItem = rawEpisodes[epIndex];
      final lineIndex = episodeItem.lineAt(probe.preferredLine) != null
          ? probe.preferredLine
          : episodeItem.availableLineIndexes.firstOrNull ?? 1;
      probe.resolvedLineIndex = lineIndex;

      final readyData = videoData.copyWith(
        episodeIndex: epIndex,
        lineIndex: lineIndex,
      );

      probe.data = readyData;
      _resolved.put(probe.item.key, readyData);

      if (!resolveMedia) {
        // 仅目录：不冒充已验证直链；点选时再升级解析媒体。
        final token = episodeItem.lineAt(lineIndex);
        probe.routeKey = _routeKeyFor(token);
        probe.status = SourceProbeStatus.playable;
        _emitProgress();
        return probe;
      }

      return _attachMedia(
        probe,
        readyData,
        episodeItem,
        epIndex,
        lineIndex,
        raceMode: raceMode,
      );
    } catch (e) {
      SourceOperation.check();
      probe.status = SourceProbeStatus.failed;
      probe.error = e.toString();
      _emitProgress();
      return probe;
    }
  }

  /// 解析真实媒体地址；必要时轮换线路。成功则写入预取（episodeId = 线路 token）。
  Future<SourceProbeState> _attachMedia(
    SourceProbeState probe,
    PlaybackRequest readyData,
    PlaybackEpisode episodeItem,
    int epIndex,
    int preferredLineIndex, {
    bool raceMode = false,
  }) async {
    final sourceKey = readyData.source;
    final lineCount = episodeItem.lines.length;
    if (lineCount <= 0) {
      probe.status = SourceProbeStatus.failed;
      probe.error = '无线路可播';
      probe.data = readyData;
      _emitProgress();
      return probe;
    }

    // 站内源：目录就绪即可选；若线路已是媒体直链则顺便预取。
    if (sourceKey == 'internal') {
      final token = episodeItem.lineAt(preferredLineIndex)?.trim() ?? '';
      probe.routeKey = _routeKeyFor(token);
      if (MediaReadiness.isAcceptablePlaybackUrl(token)) {
        return _acceptMedia(
          probe,
          readyData,
          episodeIndex: epIndex,
          lineIndex: preferredLineIndex,
          lineToken: token,
          url: token,
          httpHeaders: const {},
        );
      }
      probe.status = SourceProbeStatus.playable;
      _emitProgress();
      return probe;
    }

    final preferred = preferredLineIndex >= 1 && preferredLineIndex <= lineCount
        ? preferredLineIndex
        : 1;
    return raceMode
        ? _raceMediaLines(probe, readyData, episodeItem, epIndex, preferred)
        : _scanMediaLines(probe, readyData, episodeItem, epIndex, preferred);
  }

  /// 自动匹配竞速档：并发探测候选线路，第一条可用直链即获胜。
  ///
  /// 串行扫描最坏需要「线路数 × 单线路预算」，必然超出候选总预算；并发后
  /// 最坏情况收敛到单线路预算。
  Future<SourceProbeState> _raceMediaLines(
    SourceProbeState probe,
    PlaybackRequest readyData,
    PlaybackEpisode episodeItem,
    int epIndex,
    int preferred,
  ) async {
    final sourceKey = readyData.source;
    final lineCount = episodeItem.lines.length;

    // 首选线路优先，其余按顺序补齐到竞速上限。
    final planned = <(int, String)>[];
    final tokens = <String>{};
    var considered = 0;
    for (var index = 0; index <= lineCount; index++) {
      if (considered >= _autoMatchMaxLines) break;
      final line = index == 0 ? preferred : index;
      if (index != 0 && line == preferred) continue;
      final token = episodeItem.lineAt(line)?.trim() ?? '';
      if (token.isEmpty) continue;
      considered++;
      if (tokens.add(token)) planned.add((line, token));
    }
    if (planned.isEmpty) return _failProbe(probe, readyData, '无线路可播');

    final done =
        Completer<
          (int, String, ({String url, Map<String, String> httpHeaders}))?
        >();
    var remaining = planned.length;
    var timedOut = false;
    Object? lastError;

    Future<void> probeLine(int lineIndex, String token) async {
      final resolve = _trackAutoWork(
        resolveLineMedia(
          sourceKey: sourceKey,
          lineToken: token,
          raceMode: true,
        ),
      );
      ({String url, Map<String, String> httpHeaders})? media;
      try {
        media = await resolve.timeout(raceMediaTimeout);
      } on TimeoutException {
        // 超时只说明这次没等到，解析本身仍在跑：回来后补记为可即播。
        timedOut = true;
        _adoptLateMediaResult(
          probe: probe,
          readyData: readyData,
          episodeIndex: epIndex,
          lineIndex: lineIndex,
          lineToken: token,
          resolve: resolve,
        );
      } catch (error) {
        lastError = error;
      }
      if (media != null) {
        if (MediaReadiness.isAcceptablePlaybackUrl(media.url)) {
          if (!done.isCompleted) done.complete((lineIndex, token, media));
          return;
        }
        lastError = '线路 $lineIndex 返回不可播地址';
      }
      if (!done.isCompleted && --remaining <= 0) done.complete(null);
    }

    unawaited(
      Future.wait([
        for (final (lineIndex, token) in planned) probeLine(lineIndex, token),
      ]),
    );

    final winner = await done.future;
    SourceOperation.check();
    if (probe.isInstantPlayable) return probe;
    if (winner == null) {
      return _failProbe(
        probe,
        readyData,
        timedOut ? '直链解析超时，仍在后台解析' : lastError?.toString() ?? '无法解析播放地址',
        timedOut: timedOut,
      );
    }

    final (lineIndex, token, media) = winner;
    return _acceptMedia(
      probe,
      readyData,
      episodeIndex: epIndex,
      lineIndex: lineIndex,
      lineToken: token,
      url: media.url,
      httpHeaders: media.httpHeaders,
    );
  }

  SourceProbeState _failProbe(
    SourceProbeState probe,
    PlaybackRequest readyData,
    String error, {
    bool timedOut = false,
  }) {
    probe
      ..data = readyData
      ..status = timedOut
          ? SourceProbeStatus.playable
          : SourceProbeStatus.failed
      ..error = error;
    if (timedOut) _resolved.put(probe.item.key, readyData);
    _emitProgress();
    return probe;
  }

  SourceProbeState _acceptMedia(
    SourceProbeState probe,
    PlaybackRequest readyData, {
    required int episodeIndex,
    required int lineIndex,
    required String lineToken,
    required String url,
    required Map<String, String> httpHeaders,
  }) {
    readyData.lineIndex = lineIndex;
    // episodeId 必须与 PlaybackContent.currentEpisodeId（线路 token）一致。
    readyData.storePrefetched(
      episodeIndex: episodeIndex,
      lineIndex: lineIndex,
      episodeId: lineToken,
      url: url,
      httpHeaders: httpHeaders,
    );
    probe
      ..resolvedLineIndex = lineIndex
      ..routeKey = _routeKeyFor(lineToken)
      ..mediaUrl = url
      ..data = readyData
      ..status = SourceProbeStatus.direct
      ..error = null;
    _resolved.put(probe.item.key, readyData);
    _emitProgress();
    return probe;
  }

  /// 手动点选档：串行轮换线路，逐条等待，避免一次点选打出一串并发请求。
  Future<SourceProbeState> _scanMediaLines(
    SourceProbeState probe,
    PlaybackRequest readyData,
    PlaybackEpisode episodeItem,
    int epIndex,
    int preferred,
  ) async {
    final sourceKey = readyData.source;
    final lineCount = episodeItem.lines.length;
    final lineTimeout = manualMediaTimeout;
    Object? lastError;
    var timedOut = false;
    var nextLine = 1;
    for (
      var attempt = 0;
      attempt < _manualMaxLines && attempt < lineCount;
      attempt++
    ) {
      if (probe.isInstantPlayable) return probe;
      final int lineIndex;
      if (attempt == 0) {
        lineIndex = preferred;
      } else {
        while (nextLine == preferred) {
          nextLine++;
        }
        lineIndex = nextLine++;
      }

      final token = episodeItem.lineAt(lineIndex)?.trim() ?? '';
      if (token.isEmpty) continue;

      final resolve = resolveLineMedia(
        sourceKey: sourceKey,
        lineToken: token,
        raceMode: false,
      );
      try {
        final media = await resolve.timeout(lineTimeout);
        SourceOperation.check();
        if (probe.isInstantPlayable) return probe;

        if (!MediaReadiness.isAcceptablePlaybackUrl(media.url)) {
          lastError = '线路 $lineIndex 返回不可播地址';
          continue;
        }

        return _acceptMedia(
          probe,
          readyData,
          episodeIndex: epIndex,
          lineIndex: lineIndex,
          lineToken: token,
          url: media.url,
          httpHeaders: media.httpHeaders,
        );
      } catch (e) {
        SourceOperation.check();
        if (probe.isInstantPlayable) return probe;
        lastError = e;
        if (e is TimeoutException) {
          timedOut = true;
          // 超时只是「这次没等到」，不代表死链：WebView 嗅探这类慢解析
          // 仍在跑，回来后把结果补记为可即播（见 _adoptLateMediaResult）。
          _adoptLateMediaResult(
            probe: probe,
            readyData: readyData,
            episodeIndex: epIndex,
            lineIndex: lineIndex,
            lineToken: token,
            resolve: resolve,
          );
        }
      }
    }

    // 媒体全失败：保留目录供 UI 展示，但不标为 direct，避免误匹配。
    if (probe.isInstantPlayable) return probe;
    return _failProbe(
      probe,
      readyData,
      timedOut ? '直链解析超时，仍在后台解析' : lastError?.toString() ?? '无法解析播放地址',
      timedOut: timedOut,
    );
  }

  /// 竞速档单线路媒体解析预算。
  @protected
  Duration get raceMediaTimeout => _mediaTimeout;

  /// 手动点选档单线路媒体解析预算。
  @protected
  Duration get manualMediaTimeout => _manualMediaTimeout;

  void _adoptLateMediaResult({
    required SourceProbeState probe,
    required PlaybackRequest readyData,
    required int episodeIndex,
    required int lineIndex,
    required String lineToken,
    required Future<({String url, Map<String, String> httpHeaders})> resolve,
  }) {
    final runId = _runId;
    unawaited(
      _trackAutoWork(
        resolve
            .then((media) {
              if (!_alive(runId) ||
                  SourceOperation.current?.isCancelled == true) {
                return;
              }
              if (probe.isInstantPlayable) return;
              if (!MediaReadiness.isAcceptablePlaybackUrl(media.url)) return;

              _acceptMedia(
                probe,
                readyData,
                episodeIndex: episodeIndex,
                lineIndex: lineIndex,
                lineToken: lineToken,
                url: media.url,
                httpHeaders: media.httpHeaders,
              );
              if (kDebugMode) {
                debugPrint('[AutoMatch] late media accepted: ${media.url}');
              }
              if (autoMatchMode &&
                  !_autoMatched &&
                  !_userSelected &&
                  !_autoMatchSettled) {
                _claimAutoMatch(runId, probe.item, readyData);
              }
            })
            .catchError((Object _) {}),
      ),
    );
  }

  /// 解析单条线路的真实媒体地址（含可达性校验）。
  ///
  /// 声明为 protected 是为了让测试可以替换慢解析，验证「超时后补记结果」。
  @protected
  Future<({String url, Map<String, String> httpHeaders})> resolveLineMedia({
    required String sourceKey,
    required String lineToken,
    bool raceMode = false,
  }) async {
    final operation = SourceOperation(
      parent: SourceOperation.current ?? _sourceOperation,
      timeout: const Duration(seconds: 15),
    );
    try {
      return await operation.run(() async {
        final kind = MediaReadiness.classify(lineToken);
        final adapter = _adapter.adapterFor(sourceKey);
        final reachTimeout = raceMode
            ? _reachTimeout
            : const Duration(milliseconds: 2500);

        if (kind == MediaTokenKind.torrent) {
          return (url: lineToken, httpHeaders: const <String, String>{});
        }

        if (kind == MediaTokenKind.directMedia) {
          final headers = <String, String>{...?adapter?.mediaValidationHeaders}
            ..removeWhere((_, v) => v.isEmpty);
          if (VideoUrlExtractor.isSignedCdnUrl(lineToken)) {
            headers.removeWhere((k, _) => k.toLowerCase() == 'referer');
          }
          // 形态像直链仍要探测可达：baofeng 等空壳 m3u8 必须在此处被挡掉。
          final reachable = adapter == null
              ? true
              : await adapter.isPlaybackUrlReachable(
                  lineToken,
                  timeout: reachTimeout,
                );
          if (!reachable) {
            return (url: '', httpHeaders: const <String, String>{});
          }
          return (url: lineToken, httpHeaders: headers);
        }

        // 必须校验：不可达则返回空，上层换线/换源，绝不预取死链。
        if (adapter == null) {
          throw StateError('Source adapter is unavailable: $sourceKey');
        }
        return adapter.resolvePlaybackMedia(
          lineToken,
          skipValidation: false,
          maxAttempts: 1,
          reachTimeout: reachTimeout,
        );
      });
    } finally {
      operation.close();
    }
  }

  String _routeKeyFor(String? token) {
    final value = token?.trim() ?? '';
    if (value.isEmpty) return 'candidate:empty';
    final kind = MediaReadiness.classify(value);
    return switch (kind) {
      MediaTokenKind.directMedia => 'media:${_norm(value)}',
      MediaTokenKind.torrent => 'bt:${_norm(value)}',
      MediaTokenKind.needsResolve => 'token:${_norm(value)}',
      MediaTokenKind.empty => 'candidate:empty',
    };
  }

  Future<PlaybackRequest> resolveVideoData(SearchResultItem item) =>
      _resolved.get(item.key, () => _doResolveVideoData(item));

  Future<PlaybackRequest> _doResolveVideoData(SearchResultItem item) async {
    final operation = SourceOperation(
      parent: SourceOperation.current ?? _sourceOperation,
      timeout: const Duration(seconds: 10),
    );
    try {
      return await operation.run(() async {
        final request = item.sourceType == 'internal'
            ? PlaybackRequest.fromMap({
                ...item.result.internalData!,
                'source': 'internal',
              })
            : await _adapter.buildPlaybackRequest(item.result);
        if (request == null) {
          throw StateError(
            'Source returned no playback catalog: ${item.sourceType}',
          );
        }
        return _mergeSeed(request);
      });
    } finally {
      operation.close();
    }
  }

  PlaybackRequest _mergeSeed(PlaybackRequest request) {
    final seed = seedData;
    if (seed == null) return request;
    Map<String, dynamic>? metadata;
    for (final key in const [
      'bgmId',
      'score',
      'bgmDetailData',
      'bgmImageUrl',
      'logoUrl',
    ]) {
      final value = seed[key];
      if (value != null) {
        (metadata ??= Map.of(request.metadata))[key] = value;
      }
    }
    return metadata == null ? request : request.copyWith(metadata: metadata);
  }
}
