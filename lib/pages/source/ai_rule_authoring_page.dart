import 'dart:convert';

import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/pages/setting/ai_rule_settings_page.dart';
import 'package:baka/services/source/ai_rule_settings.dart';
import 'package:baka/services/source/ai_rule_authoring_service.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum _TestStage { search, episodes, playback }

class AiRuleAuthoringPage extends StatefulWidget {
  const AiRuleAuthoringPage({super.key, this.seed, this.source});

  final RuleAuthoringSeed? seed;
  final CustomSourceConfig? source;

  @override
  State<AiRuleAuthoringPage> createState() => _AiRuleAuthoringPageState();
}

class _AiRuleAuthoringPageState extends State<AiRuleAuthoringPage> {
  static const _quickKeywords = ['孤独摇滚', '葬送的芙莉莲', '迷宫饭', '鬼灭之刃'];
  static const _emptyPipeline = <String, dynamic>{
    'search': <dynamic>[],
    'detail': <dynamic>[],
    'play': <dynamic>[],
  };

  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _siteController;
  late final TextEditingController _keywordController;
  late final TextEditingController _instructionsController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _pipelineController;
  late final String _sourceId;

  AiProviderConfig? _provider;
  AiRuleAuthoringService? _service;
  RuleAuthoringResult? _result;
  RuleAuthoringProgress? _progress;
  final List<String> _traceLogs = [];
  String? _analysisSummary;
  String? _error;

  bool _loading = true;
  bool _running = false;
  bool _saving = false;
  bool _enabled = true;
  bool _showAdvanced = false;
  int _maxRounds = 35;

  _TestStage? _runningTest;
  String? _testSeriesUrl;
  String? _testEpisodeUrl;
  final Map<_TestStage, String> _testLogs = {
    for (final stage in _TestStage.values) stage: '',
  };

  bool get _isBuiltinSource {
    final key = widget.source?.id ?? widget.seed?.sourceKey;
    return key != null && AdapterRegistry.isBuiltinSource(key);
  }

  bool get _isRepairing =>
      widget.seed?.mode == RuleAuthoringMode.repair ||
      widget.seed?.failureMessage != null;

  RuleAuthoringMode get _mode {
    if (widget.seed != null) return widget.seed!.mode;
    return _isRepairing ? RuleAuthoringMode.repair : RuleAuthoringMode.create;
  }

  bool get _isEditingExisting =>
      widget.source != null || widget.seed?.currentConfig != null;

  @override
  void initState() {
    super.initState();
    final source = widget.source ?? widget.seed?.currentConfig;
    final seed = widget.seed;

    _sourceId = source?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    _maxRounds = seed?.maxRounds ?? 35;
    _enabled = source?.enabled ?? true;

    _nameController = TextEditingController(text: source?.name ?? '');
    _siteController = TextEditingController(
      text: seed?.siteUrl ?? source?.baseUrl ?? '',
    );
    _keywordController = TextEditingController(
      text: seed?.keyword.trim().isNotEmpty == true ? seed!.keyword : '孤独摇滚',
    );
    _instructionsController = TextEditingController(
      text: seed?.instructions ?? '',
    );
    _descriptionController = TextEditingController(
      text: source?.description ?? '',
    );
    _pipelineController = TextEditingController(
      text: _encodePipeline(source?.pipeline ?? _emptyPipeline),
    );

    if (seed?.instructions.isNotEmpty == true) _showAdvanced = true;
    _loadProvider();
  }

  Future<void> _loadProvider() async {
    final provider = await AiRuleSettingsService.instance.load();
    if (!mounted) return;
    setState(() {
      _provider = provider;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _service?.cancel();
    _nameController.dispose();
    _siteController.dispose();
    _keywordController.dispose();
    _instructionsController.dispose();
    _descriptionController.dispose();
    _pipelineController.dispose();
    super.dispose();
  }

  static String _encodePipeline(Map<String, dynamic> pipeline) =>
      const JsonEncoder.withIndent('  ').convert(pipeline);

  Map<String, dynamic>? _parsePipeline([String? input]) {
    try {
      final decoded = jsonDecode(input ?? _pipelineController.text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  String? _validateSite(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return '请输入有效的 HTTP(S) 站点主页';
    }
    return null;
  }

  CustomSourceConfig _buildConfig(Map<String, dynamic> pipeline) {
    final original = widget.source ?? widget.seed?.currentConfig;
    final name = _nameController.text.trim();
    return CustomSourceConfig(
      id: _sourceId,
      name: name.isNotEmpty ? name : '未命名图源',
      baseUrl: _siteController.text.trim(),
      iconUrl: original?.iconUrl,
      description: _descriptionController.text.trim(),
      pipeline: pipeline,
      enabled: _enabled,
      createdAt: original?.createdAt,
    );
  }

  SourceRule? _validateCurrentRule({bool showMessage = true}) {
    FocusManager.instance.primaryFocus?.unfocus();
    final pipeline = _parsePipeline();
    if (pipeline == null || pipeline.isEmpty) {
      if (showMessage) showSnackBar('请先生成或填入规则 JSON', isError: true);
      return null;
    }
    final rule = _buildConfig(pipeline).toSourceRule();
    final validation = RuleValidator.validate(rule);
    if (!validation.isValid) {
      if (showMessage) {
        showSnackBar('规则校验未通过：${validation.errors.join('；')}', isError: true);
      }
      return null;
    }
    return rule;
  }

  Future<void> _openSettings() async {
    HapticFeedback.lightImpact();
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AiRuleSettingsPage()),
    );
    if (mounted) await _loadProvider();
  }

  Future<void> _start() async {
    if (_running || !(_formKey.currentState?.validate() ?? false)) return;
    final provider = _provider;
    if (provider == null || !provider.isConfigured) {
      await _openSettings();
      return;
    }

    HapticFeedback.mediumImpact();
    final original = widget.seed;
    final seed = RuleAuthoringSeed(
      mode: _mode,
      siteUrl: _siteController.text.trim(),
      keyword: _keywordController.text.trim(),
      instructions: _instructionsController.text.trim(),
      sourceKey: original?.sourceKey ?? widget.source?.id,
      currentConfig: widget.source ?? original?.currentConfig,
      seriesId: original?.seriesId,
      episodeId: original?.episodeId,
      failureMessage: original?.failureMessage,
      maxRounds: _maxRounds,
    );

    final service = AiRuleAuthoringService();
    setState(() {
      _service = service;
      _running = true;
      _result = null;
      _error = null;
      _progress = null;
      _analysisSummary = null;
      _traceLogs.clear();
    });

    try {
      final result = await service.run(
        provider: provider,
        seed: seed,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            if (progress.stage == 'summary') {
              _analysisSummary = progress.message;
            } else {
              _progress = progress;
              final msg = progress.message.trim();
              if (msg.isNotEmpty &&
                  (_traceLogs.isEmpty || _traceLogs.last != msg)) {
                _traceLogs.add(
                  'R${progress.round} [${progress.stage.toUpperCase()}] $msg',
                );
                if (_traceLogs.length > 50) _traceLogs.removeAt(0);
              }
            }
          });
        },
      );
      if (mounted) {
        setState(() {
          _result = result;
          if (_nameController.text.trim().isEmpty) {
            _nameController.text = result.config.name;
          }
          if (result.config.baseUrl.isNotEmpty) {
            _siteController.text = result.config.baseUrl;
          }
          if (result.config.pipeline != null) {
            _pipelineController.text = _encodePipeline(result.config.pipeline!);
          }
        });
        HapticFeedback.heavyImpact();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
        HapticFeedback.heavyImpact();
      }
    } finally {
      service.cancel();
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    HapticFeedback.mediumImpact();

    final rule = _validateCurrentRule();
    if (rule == null) return;

    setState(() => _saving = true);
    try {
      final config = _buildConfig(_parsePipeline()!);
      final sourceKey = widget.seed?.sourceKey ?? widget.source?.id;
      final catalog = sourceCatalog;

      bool saved;
      if (sourceKey != null && AdapterRegistry.isBuiltinSource(sourceKey)) {
        saved = await catalog.updateBuiltinSource(sourceKey, config);
      } else if (sourceKey != null &&
          (widget.source != null ||
              AdapterRegistry.isCustomSource(sourceKey))) {
        saved = await catalog.updateCustomSource(config);
      } else {
        saved = await catalog.addCustomSource(config);
      }

      if (!mounted) return;
      if (!saved) {
        showSnackBar('规则保存失败：来源已变更或 ID 冲突', isError: true);
        return;
      }
      showSnackBar(
        _isRepairing ? '规则已保存' : (_isBuiltinSource ? '内置源本地规则已保存' : '图源已保存并启用'),
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) showSnackBar('保存失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _formatPipeline() {
    final pipeline = _parsePipeline();
    if (pipeline == null) {
      showSnackBar('规则 JSON 格式无效', isError: true);
      return;
    }
    _pipelineController.value = TextEditingValue(
      text: _encodePipeline(pipeline),
      selection: const TextSelection.collapsed(offset: 0),
    );
    showSnackBar('规则已格式化');
  }

  Future<void> _pastePipeline() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text?.trim();
    if (text == null || text.isEmpty) {
      showSnackBar('剪贴板中没有文本', isError: true);
      return;
    }

    try {
      final decoded = SourceCodec.decode(text);
      if (decoded is! Map) throw const FormatException();
      final json = Map<String, dynamic>.from(decoded);
      final pipeline = json['pipeline'] is Map
          ? Map<String, dynamic>.from(json['pipeline'] as Map)
          : <String, dynamic>{
              if (json['recipes'] != null) 'recipes': json['recipes'],
              if (json['headers'] != null) 'headers': json['headers'],
              if (json['search'] != null) 'search': json['search'],
              if (json['detail'] != null) 'detail': json['detail'],
              if (json['play'] != null) 'play': json['play'],
              if (json['useWebview'] != null) 'useWebview': json['useWebview'],
              if (json['directConnection'] != null)
                'directConnection': json['directConnection'],
            };
      if (pipeline.isEmpty) throw const FormatException();

      setState(() {
        _pipelineController.text = _encodePipeline(pipeline);
        if (json['name'] != null && _nameController.text.trim().isEmpty) {
          _nameController.text = json['name'].toString();
        }
        if (json['baseUrl'] != null && _siteController.text.trim().isEmpty) {
          _siteController.text = json['baseUrl'].toString();
        }
        _testSeriesUrl = null;
        _testEpisodeUrl = null;
        for (final stage in _TestStage.values) {
          _testLogs[stage] = '';
        }
      });
      showSnackBar('已成功导入规则');
    } catch (_) {
      showSnackBar('剪贴板内容不是合法的规则或分享链接', isError: true);
    }
  }

  void _copyJson() {
    final rule = _validateCurrentRule();
    if (rule == null) return;
    Clipboard.setData(
      ClipboardData(
        text: _encodePipeline(_buildConfig(_parsePipeline()!).toJson()),
      ),
    );
    showSnackBar('配置 JSON 已复制');
  }

  void _copyShareLink() {
    final rule = _validateCurrentRule();
    if (rule == null) return;
    Clipboard.setData(
      ClipboardData(
        text: SourceCodec.encode(_buildConfig(_parsePipeline()!).toJson()),
      ),
    );
    showSnackBar('baka:// 分享链接已复制');
  }

  Future<void> _runTest(
    _TestStage stage,
    Future<String> Function(PipelineSourceAdapter adapter) action,
  ) async {
    if (_runningTest != null) return;
    final rule = _validateCurrentRule();
    if (rule == null) return;

    HapticFeedback.mediumImpact();
    setState(() {
      _runningTest = stage;
      if (stage == _TestStage.search) {
        _testSeriesUrl = null;
        _testEpisodeUrl = null;
        _testLogs[stage] = '🔍 搜索 ${_keywordController.text.trim()}...\n';
        _testLogs[_TestStage.episodes] = '';
        _testLogs[_TestStage.playback] = '';
      } else if (stage == _TestStage.episodes) {
        _testEpisodeUrl = null;
        _testLogs[stage] = '📺 解析详情与剧集...\n';
        _testLogs[_TestStage.playback] = '';
      } else {
        _testLogs[stage] = '🎬 解析视频播放直链...\n';
      }
    });

    try {
      final adapter = PipelineSourceAdapter(rule);
      final log = await action(adapter);
      if (mounted) setState(() => _testLogs[stage] = log);
    } catch (error, stackTrace) {
      if (!mounted) return;
      final stack = stackTrace.toString().split('\n').take(2).join('\n');
      setState(
        () => _testLogs[stage] = '${_testLogs[stage]}❌ 失败：$error\n$stack',
      );
    } finally {
      if (mounted) setState(() => _runningTest = null);
    }
  }

  void _testSearch() {
    _runTest(_TestStage.search, (adapter) async {
      final keyword = _keywordController.text.trim();
      if (keyword.isEmpty) throw const FormatException('请输入测试关键词');
      final results = await adapter.search(keyword);
      if (results.isEmpty) return '⚠️ 未找到搜索结果';
      _testSeriesUrl = results.first.seriesId;
      final preview = results
          .take(3)
          .map((e) => '• ${e.name} (${e.seriesId})')
          .join('\n');
      return '✅ 成功命中 ${results.length} 部番剧：\n$preview';
    });
  }

  void _testEpisodes() {
    final seriesUrl = _testSeriesUrl;
    if (seriesUrl == null) return;
    _runTest(_TestStage.episodes, (adapter) async {
      final catalog = await adapter.getPlaybackCatalog(seriesUrl);
      if (catalog.isEmpty) return '⚠️ 未提取到播放线路';
      _testEpisodeUrl = catalog.episodes.first.lines.first;
      return '✅ 解析成功：${catalog.sourceNames.length} 条线路，共 ${catalog.episodes.length} 集\n线路：${catalog.sourceNames.join('、')}';
    });
  }

  void _testPlayback() {
    final episodeUrl = _testEpisodeUrl;
    if (episodeUrl == null) return;
    _runTest(_TestStage.playback, (adapter) async {
      final url = await adapter.resolveDownloadUrl(
        episodeUrl,
        forceRefresh: true,
      );
      return url.isEmpty ? '⚠️ 未提取到播放直链' : '✅ 播放直链解析成功：\n$url';
    });
  }

  // ===================== 左侧：现代化极简 Studio 侧边栏 (色调与右侧一致) =====================

  Widget _buildStudioSidebar(BuildContext context, {bool isWide = true}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = context.primaryColor;
    final isRepair = _mode == RuleAuthoringMode.repair;
    final isConfigured = _provider?.isConfigured == true;

    final cardFill = isDark ? const Color(0xFF1E1E22) : Colors.white;
    final inputFill = isDark
        ? const Color(0xFF141416)
        : const Color(0xFFF3F4F6);
    final borderColor = isDark ? Colors.white12 : const Color(0xFFE5E7EB);

    final content = <Widget>[
      // 1. Studio Header 卡片
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardFill,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isRepair
                          ? [const Color(0xFFF59E0B), const Color(0xFFD97706)]
                          : [primary, primary.withValues(alpha: 0.75)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isRepair ? Icons.build_rounded : Icons.auto_awesome_rounded,
                    size: 20,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isRepairing
                            ? 'REPAIR STUDIO'
                            : (_isBuiltinSource
                                  ? 'BUILTIN CUSTOMIZER'
                                  : 'RULE SYNTHESIZER'),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.4,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                      ),
                      Text(
                        _isRepairing
                            ? '图源逆向修复'
                            : (_isBuiltinSource
                                  ? '内置规则定制'
                                  : (_isEditingExisting
                                        ? '图源参数配置'
                                        : 'AI 规则创作台')),
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: _openSettings,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: isConfigured
                          ? const Color(0xFF10B981).withValues(alpha: 0.12)
                          : const Color(0xFFF59E0B).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isConfigured
                                ? const Color(0xFF10B981)
                                : const Color(0xFFF59E0B),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isConfigured ? _provider!.model : '配置模型',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isConfigured
                                ? const Color(0xFF10B981)
                                : const Color(0xFFD97706),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (isRepair && widget.seed?.failureMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFD97706).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFFD97706).withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  '异常诊断：${widget.seed!.failureMessage}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFFD97706),
                    height: 1.35,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),

      const SizedBox(height: 14),

      // 2. 目标站点与测试样本卡片
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardFill,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStudioLabel('TARGET HOST', Icons.language_rounded),
            const SizedBox(height: 6),
            TextFormField(
              controller: _siteController,
              validator: _validateSite,
              readOnly: _running,
              keyboardType: TextInputType.url,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: 'https://example.com',
                prefixIcon: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  margin: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white10
                        : Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'URL',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 0,
                  minHeight: 0,
                ),
                filled: true,
                fillColor: inputFill,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 14),

            _buildStudioLabel('PROBE ANIME', Icons.search_rounded),
            const SizedBox(height: 6),
            TextFormField(
              controller: _keywordController,
              validator: (v) => v?.trim().isEmpty == true ? '请输入测试番剧名' : null,
              readOnly: _running,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: '站点内可搜索到的番剧名',
                filled: true,
                fillColor: inputFill,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _quickKeywords.map((kw) {
                final isSelected = _keywordController.text.trim() == kw;
                return InkWell(
                  onTap: _running
                      ? null
                      : () => setState(() => _keywordController.text = kw),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? primary
                          : (isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.04)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      kw,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: isSelected
                            ? FontWeight.w800
                            : FontWeight.w500,
                        color: isSelected
                            ? Colors.white
                            : (isDark ? Colors.white70 : Colors.black87),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),

            _buildStudioLabel('EXPLORATION ROUNDS', Icons.speed_rounded),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: inputFill,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [35, 50, 60, 0].map((rounds) {
                  final isSelected = _maxRounds == rounds;
                  final label = rounds == 0
                      ? '不限制'
                      : (rounds == 50 ? '50轮★' : '$rounds轮');
                  return Expanded(
                    child: GestureDetector(
                      onTap: _running
                          ? null
                          : () => setState(() => _maxRounds = rounds),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? (isDark
                                    ? const Color(0xFF2C2C30)
                                    : Colors.white)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.1),
                                    blurRadius: 4,
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: isSelected
                                ? FontWeight.w800
                                : FontWeight.w500,
                            color: isSelected
                                ? (isDark ? Colors.white : Colors.black87)
                                : (isDark ? Colors.white38 : Colors.black38),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),

      const SizedBox(height: 14),

      // 3. 图源配置元信息卡片
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardFill,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStudioLabel('SOURCE METADATA', Icons.tune_rounded),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _nameController,
                    readOnly: _running,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      hintText: '图源名称（选填，AI 提取）',
                      filled: true,
                      fillColor: inputFill,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '启用',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                    ),
                    Switch(
                      value: _enabled,
                      onChanged: (v) => setState(() => _enabled = v),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _descriptionController,
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                hintText: '图源备注说明（可选）',
                filled: true,
                fillColor: inputFill,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (_showAdvanced ||
                widget.seed?.instructions.isNotEmpty == true) ...[
              TextFormField(
                controller: _instructionsController,
                readOnly: _running,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(fontSize: 12.5),
                decoration: InputDecoration(
                  hintText: '自定义 Prompt / 抓包接口线索...',
                  filled: true,
                  fillColor: inputFill,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ] else ...[
              TextButton.icon(
                onPressed: () => setState(() => _showAdvanced = true),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text(
                  '补充线索 / 自定义 Prompt',
                  style: TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                ),
              ),
            ],
          ],
        ),
      ),
    ];

    if (!isWide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...content,
          const SizedBox(height: 14),
          _buildLeftBottomActionBar(context),
        ],
      );
    }

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 20, 14, 20),
              children: content,
            ),
          ),
          _buildLeftBottomActionBar(context),
        ],
      ),
    );
  }

  // 左栏底部：仅负责 AI 触发
  Widget _buildLeftBottomActionBar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isConfigured = _provider?.isConfigured == true;
    final hasRule = _result != null || (_parsePipeline()?.isNotEmpty == true);
    final borderColor = isDark ? Colors.white12 : const Color(0xFFE5E7EB);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E22) : Colors.white,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: FilledButton.icon(
        onPressed: _running ? null : _start,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: _running
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.auto_awesome_rounded, size: 18),
        label: Text(
          !isConfigured
              ? '配置模型'
              : (_running ? '推导中...' : (hasRule ? 'AI 重新推导' : 'AI 智能推导')),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  // 右下角常驻操作栏：包含规则就绪状态与醒目的“保存图源”按钮
  Widget _buildRightBottomActionBar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasRule = _result != null || (_parsePipeline()?.isNotEmpty == true);
    final borderColor = isDark ? Colors.white12 : const Color(0xFFE5E7EB);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E22) : Colors.white,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (hasRule) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: Color(0xFF10B981),
                      ),
                      SizedBox(width: 6),
                      Text(
                        '规则已就绪，点击右侧保存生效',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF10B981),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Text(
                  '等待 AI 逆向推导或手动填入规则 JSON',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ],
            ],
          ),
          // 右下角核心保存按钮
          FilledButton.icon(
            onPressed: (hasRule && !_saving) ? _save : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size(140, 48),
              backgroundColor: const Color(0xFF10B981),
              disabledBackgroundColor: isDark ? Colors.white12 : Colors.black12,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: _saving
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.save_rounded, size: 18),
            label: Text(
              _saving ? '保存中...' : '保存图源',
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudioLabel(String text, IconData icon) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Icon(icon, size: 13, color: isDark ? Colors.white38 : Colors.black38),
        const SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            color: isDark ? Colors.white54 : Colors.black54,
          ),
        ),
      ],
    );
  }

  // =================== AI 全流程 4 阶段可视化 (右栏全景展示) ===================

  Widget _buildPipelineWorkflowCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = context.primaryColor;

    final stage = _progress?.stage;
    int currentStep = -1;
    if (_result != null) {
      currentStep = 4;
    } else if (_running) {
      if (stage == 'probe') {
        currentStep = 0;
      } else if (stage == 'validate')
        currentStep = 2;
      else if (stage == 'success')
        currentStep = 3;
      else
        currentStep = 1;
    }

    const steps = [
      ('01', '站点探测', 'DOM与反爬扫描', Icons.radar_rounded),
      ('02', '规则推导', '路径定位代码合成', Icons.psychology_rounded),
      ('03', '沙盒验证', '真实请求直链回放', Icons.science_rounded),
      ('04', '交付就绪', 'anx-rule/2 规范封装', Icons.verified_rounded),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E22) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _running
              ? primary.withValues(alpha: 0.5)
              : (_result != null
                    ? const Color(0xFF10B981).withValues(alpha: 0.4)
                    : (isDark ? Colors.white12 : const Color(0xFFE5E7EB))),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color:
                          (_running
                                  ? primary
                                  : (_result != null
                                        ? const Color(0xFF10B981)
                                        : Colors.grey))
                              .withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _running
                          ? Icons.sync_rounded
                          : (_result != null
                                ? Icons.check_circle_rounded
                                : Icons.timeline_rounded),
                      size: 20,
                      color: _running
                          ? primary
                          : (_result != null
                                ? const Color(0xFF10B981)
                                : Colors.grey),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'AI 智能全链路逆向流水线',
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w900,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              ),
              if (_running && _progress != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '探索中: ${_progress!.round}/$_maxRounds 轮',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: primary,
                    ),
                  ),
                )
              else if (_result != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '沙盒验证 100% 通过',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF10B981),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),

          Row(
            children: [
              for (int i = 0; i < steps.length; i++) ...[
                Expanded(
                  child: _buildStageItem(
                    index: steps[i].$1,
                    title: steps[i].$2,
                    subtitle: steps[i].$3,
                    icon: steps[i].$4,
                    isActive: currentStep == i,
                    isDone: currentStep > i,
                    isDark: isDark,
                    primary: primary,
                  ),
                ),
                if (i < steps.length - 1)
                  Container(
                    width: 14,
                    height: 2,
                    margin: const EdgeInsets.only(bottom: 24),
                    color: currentStep > i
                        ? const Color(0xFF10B981)
                        : (isDark ? Colors.white12 : Colors.black12),
                  ),
              ],
            ],
          ),

          if (_running && _progress?.message.isNotEmpty == true) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: isDark ? 0.15 : 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: primary.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '⚡ 正在执行：${_progress!.message}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (_analysisSummary != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(
                  0xFF0284C7,
                ).withValues(alpha: isDark ? 0.15 : 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF0284C7).withValues(alpha: 0.25),
                ),
              ),
              child: Text(
                '💡 站点逆向结构洞察：$_analysisSummary',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ),
          ],

          if (_traceLogs.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '实时推导动作轨迹 (${_traceLogs.length})',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                if (_running)
                  TextButton.icon(
                    onPressed: _service?.cancel,
                    icon: const Icon(
                      Icons.stop_circle_outlined,
                      size: 15,
                      color: Colors.redAccent,
                    ),
                    label: const Text(
                      '中止任务',
                      style: TextStyle(fontSize: 11.5, color: Colors.redAccent),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 120),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF121214),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                reverse: true,
                itemCount: _traceLogs.length,
                itemBuilder: (context, idx) {
                  final item = _traceLogs[_traceLogs.length - 1 - idx];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      item,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: Color(0xFF93C5FD),
                        height: 1.35,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStageItem({
    required String index,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isActive,
    required bool isDone,
    required bool isDark,
    required Color primary,
  }) {
    final Color circleColor = isDone
        ? const Color(0xFF10B981)
        : (isActive
              ? primary
              : (isDark ? const Color(0xFF2C2C30) : const Color(0xFFE5E7EB)));
    final Color textColor = isDone
        ? const Color(0xFF10B981)
        : (isActive ? primary : (isDark ? Colors.white70 : Colors.black87));

    return Column(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: circleColor,
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: primary.withValues(alpha: 0.4),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: isDone
                ? const Icon(Icons.check, size: 18, color: Colors.white)
                : (isActive
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          icon,
                          size: 16,
                          color: isDark ? Colors.white38 : Colors.black38,
                        )),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: isActive || isDone ? FontWeight.w800 : FontWeight.w600,
            color: textColor,
          ),
        ),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
        ),
      ],
    );
  }

  // 成功 4 宫格超大字指标看板
  Widget _buildResultBoard(BuildContext context) {
    final result = _result;
    if (result == null) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E22) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF10B981).withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFF10B981),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check, size: 20, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '推导与沙盒验证成功',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    Text(
                      '历经 ${result.rounds} 轮探索，已成功提取有效播放流',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildMetricTile(
                  label: '搜索结果',
                  value: '${result.validation.seriesCount}',
                  unit: '部',
                  color: const Color(0xFF0284C7),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMetricTile(
                  label: '解析线路',
                  value: '${result.validation.lineCount}',
                  unit: '条',
                  color: const Color(0xFF8B5CF6),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMetricTile(
                  label: '剧集提取',
                  value: '${result.validation.episodeCount}',
                  unit: '集',
                  color: const Color(0xFF10B981),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMetricTile(
                  label: '媒体格式',
                  value: result.validation.mediaKind ?? 'HLS',
                  unit: '',
                  color: const Color(0xFFD97706),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required String label,
    required String value,
    required String unit,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // 规则 JSON 纯黑大色块视窗
  Widget _buildRuleEditorCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF121214),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'PIPELINE JSON',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                    color: Color(0xFF10B981),
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.format_align_left_rounded,
                        size: 18,
                        color: Colors.white70,
                      ),
                      tooltip: '格式化',
                      onPressed: _formatPipeline,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.content_paste_rounded,
                        size: 18,
                        color: Colors.white70,
                      ),
                      tooltip: '剪贴板粘贴',
                      onPressed: _pastePipeline,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.copy_rounded,
                        size: 18,
                        color: Colors.white70,
                      ),
                      tooltip: '复制 JSON',
                      onPressed: _copyJson,
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.share_rounded,
                        size: 18,
                        color: Colors.white70,
                      ),
                      tooltip: '分享链接',
                      onPressed: _copyShareLink,
                    ),
                  ],
                ),
              ],
            ),
          ),
          TextFormField(
            controller: _pipelineController,
            minLines: 7,
            maxLines: 14,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.45,
              color: Color(0xFF93C5FD),
            ),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              border: InputBorder.none,
            ),
          ),
        ],
      ),
    );
  }

  // 1-2-3 流水线单步调试
  Widget _buildTestPipelineCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = context.primaryColor;
    final borderColor = isDark ? Colors.white12 : const Color(0xFFE5E7EB);

    final passedSteps = [
      _testLogs[_TestStage.search]?.contains('✅') == true,
      _testLogs[_TestStage.episodes]?.contains('✅') == true,
      _testLogs[_TestStage.playback]?.contains('✅') == true,
    ].where((e) => e).length;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E22) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部：与顶部流程和规则代码视窗完全呼应的标题栏
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.play_circle_filled_rounded,
                      size: 18,
                      color: primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SANDBOX RUNNER',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.1,
                          color: primary,
                        ),
                      ),
                      Text(
                        '单步联调流水线',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: passedSteps == 3
                      ? const Color(0xFF10B981).withValues(alpha: 0.15)
                      : (isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : const Color(0xFFF3F4F6)),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: passedSteps == 3
                        ? const Color(0xFF10B981).withValues(alpha: 0.3)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      passedSteps == 3
                          ? Icons.check_circle_rounded
                          : Icons.radar_rounded,
                      size: 13,
                      color: passedSteps == 3
                          ? const Color(0xFF10B981)
                          : (isDark ? Colors.white70 : Colors.black54),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '已通过 $passedSteps/3',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: passedSteps == 3
                            ? const Color(0xFF10B981)
                            : (isDark ? Colors.white70 : Colors.black54),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 步骤 1: 检索番剧
          _buildTestStepRow(
            number: '01',
            title: '检索番剧',
            desc: '验证 search 规则，提取番剧唯一标识 ID',
            statusDetail: _testSeriesUrl != null
                ? '已提取 ID: $_testSeriesUrl'
                : null,
            stage: _TestStage.search,
            onPressed: _testSearch,
          ),
          const SizedBox(height: 10),

          // 步骤 2: 剧集与线路
          _buildTestStepRow(
            number: '02',
            title: '剧集与线路',
            desc: '解析多线路播放源与分集列表',
            statusDetail: _testSeriesUrl == null
                ? '需前置通过第 01 步检索'
                : (_testEpisodeUrl != null ? '已提取首集直链参数' : '待执行线路解析'),
            stage: _TestStage.episodes,
            onPressed: _testSeriesUrl == null ? null : _testEpisodes,
          ),
          const SizedBox(height: 10),

          // 步骤 3: 播放直链
          _buildTestStepRow(
            number: '03',
            title: '播放直链',
            desc: '嗅探并解析首选集数的直链媒体地址',
            statusDetail: _testEpisodeUrl == null ? '需前置通过第 02 步线路' : '已就绪直链测试',
            stage: _TestStage.playback,
            onPressed: _testEpisodeUrl == null ? null : _testPlayback,
          ),
        ],
      ),
    );
  }

  Widget _buildTestStepRow({
    required String number,
    required String title,
    required String desc,
    required _TestStage stage,
    required VoidCallback? onPressed,
    String? statusDetail,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = context.primaryColor;
    final isRunning = _runningTest == stage;
    final log = _testLogs[stage] ?? '';
    final isSuccess = log.contains('✅');
    final isError = log.contains('❌');
    final isLocked = onPressed == null && !isRunning;

    // 内嵌卡片底色与边框
    final cardBg = isDark ? const Color(0xFF141416) : const Color(0xFFF9FAFB);
    final cardBorder = isSuccess
        ? const Color(0xFF10B981).withValues(alpha: 0.3)
        : (isError
              ? const Color(0xFFEF4444).withValues(alpha: 0.3)
              : (isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : const Color(0xFFE5E7EB)));

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 步骤指示微标
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSuccess
                      ? const Color(0xFF10B981).withValues(alpha: 0.18)
                      : (isError
                            ? const Color(0xFFEF4444).withValues(alpha: 0.18)
                            : (isLocked
                                  ? (isDark ? Colors.white10 : Colors.black12)
                                  : primary.withValues(alpha: 0.15))),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: isRunning
                    ? SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: primary,
                        ),
                      )
                    : (isSuccess
                          ? const Icon(
                              Icons.check_rounded,
                              size: 16,
                              color: Color(0xFF10B981),
                            )
                          : (isError
                                ? const Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                    color: Color(0xFFEF4444),
                                  )
                                : (isLocked
                                      ? Icon(
                                          Icons.lock_outline_rounded,
                                          size: 14,
                                          color: isDark
                                              ? Colors.white38
                                              : Colors.black38,
                                        )
                                      : Text(
                                          number,
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 12,
                                            fontWeight: FontWeight.w900,
                                            color: primary,
                                          ),
                                        )))),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        if (isSuccess) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF10B981,
                              ).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'PASSED',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF10B981),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusDetail ?? desc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: statusDetail != null
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: statusDetail != null && isSuccess
                            ? const Color(0xFF10B981)
                            : (isDark ? Colors.white54 : Colors.black54),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 执行胶囊按钮
              FilledButton.tonal(
                onPressed: _runningTest == null ? onPressed : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  minimumSize: Size.zero,
                  backgroundColor: isSuccess
                      ? (isDark ? Colors.white10 : const Color(0xFFE5E7EB))
                      : null,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: isRunning
                    ? const SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        isSuccess ? '重新测试' : '测试',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
            ],
          ),
          if (log.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F11),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSuccess
                      ? const Color(0xFF10B981).withValues(alpha: 0.2)
                      : (isError
                            ? const Color(0xFFEF4444).withValues(alpha: 0.2)
                            : Colors.white10),
                ),
              ),
              child: SelectableText(
                log,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.45,
                  color: isError
                      ? const Color(0xFFEF4444)
                      : (isSuccess ? const Color(0xFF34D399) : Colors.white70),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ===================== 响应式布局：大屏全景展开 / 窄屏纵向流动 =====================

  Widget _buildWideLayout(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? Colors.white12 : const Color(0xFFE5E7EB);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左栏：全景 Studio 控制台 (400px 宽度)
        SizedBox(width: 400, child: _buildStudioSidebar(context)),

        // 分割线
        VerticalDivider(width: 1, thickness: 1, color: borderColor),

        // 右栏：AI 全流程管线看板 + 成果指标 + 规则代码与单步联调全景展开 + 右下角保存栏
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 20, 24, 24),
                  children: [
                    _buildPipelineWorkflowCard(context),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.error.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).colorScheme.error.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              color: Theme.of(context).colorScheme.error,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_result != null) ...[
                      const SizedBox(height: 14),
                      _buildResultBoard(context),
                    ],
                    const SizedBox(height: 16),
                    // 规则代码与单步联调并列全景铺开
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: _buildRuleEditorCard(context)),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 5,
                          child: _buildTestPipelineCard(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 右下角常驻操作栏（保存按钮位于最右侧）
              _buildRightBottomActionBar(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowLayout(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
      children: [
        _buildStudioSidebar(context, isWide: false),
        const SizedBox(height: 16),
        _buildPipelineWorkflowCard(context),
        if (_result != null) ...[
          const SizedBox(height: 14),
          _buildResultBoard(context),
        ],
        const SizedBox(height: 14),
        _buildRuleEditorCard(context),
        const SizedBox(height: 14),
        _buildTestPipelineCard(context),
        const SizedBox(height: 16),
        _buildRightBottomActionBar(context),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isRepairing
              ? 'AI 修复图源'
              : (_isBuiltinSource
                    ? '编辑内置源'
                    : (_isEditingExisting ? '编辑图源' : 'AI 规则工坊')),
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            onPressed: _pastePipeline,
            tooltip: '粘贴导入规则',
            icon: const Icon(Icons.content_paste_rounded),
          ),
          IconButton(
            onPressed: _running ? null : _openSettings,
            tooltip: '模型参数设置',
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Form(
        key: _formKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 880;
            return isWide
                ? _buildWideLayout(context)
                : _buildNarrowLayout(context);
          },
        ),
      ),
    );
  }
}
