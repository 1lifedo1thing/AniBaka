import 'dart:async';

import 'package:baka/instance.dart';
import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/services/source/ai_rule_settings.dart';
import 'package:baka/services/source/ai_rule_authoring_service.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AiRuleSettingsPage extends StatefulWidget {
  const AiRuleSettingsPage({super.key});

  @override
  State<AiRuleSettingsPage> createState() => _AiRuleSettingsPageState();
}

class _PresetOption {
  const _PresetOption({
    required this.name,
    required this.baseUrl,
    required this.model,
    required this.description,
    this.badge,
  });

  final String name;
  final String baseUrl;
  final String model;
  final String description;
  final String? badge;
}

class _AiRuleSettingsPageState extends State<AiRuleSettingsPage> {
  static const List<_PresetOption> _presets = [
    _PresetOption(
      name: 'DeepSeek 官方',
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      description: '性价比与代码推理极高',
      badge: '推荐',
    ),
    _PresetOption(
      name: 'SiliconFlow 硅基流动',
      baseUrl: 'https://api.siliconflow.cn/v1',
      model: 'deepseek-ai/DeepSeek-V3',
      description: '国内高速接入与多模型',
    ),
    _PresetOption(
      name: 'OpenAI 官方',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
      description: '通用智能与快速解析',
    ),
    _PresetOption(
      name: 'Ollama 本地服务',
      baseUrl: 'http://localhost:11434/v1',
      model: 'qwen2.5:7b',
      description: '本地离线运行无需 Key',
    ),
  ];

  final _formKey = GlobalKey<FormState>();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _apiKeyController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _obscureKey = true;
  String? _testSuccessInfo;
  String? _testErrorInfo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await AiRuleSettingsService.instance.load();
    if (!mounted) return;
    _baseUrlController.text = config.baseUrl;
    _modelController.text = config.model;
    _apiKeyController.text = config.apiKey;
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  AiProviderConfig get _config => AiProviderConfig(
    baseUrl: _baseUrlController.text.trim(),
    model: _modelController.text.trim(),
    apiKey: _apiKeyController.text.trim(),
  );

  String? _validateBaseUrl(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return '请输入有效的 HTTP(S) Base URL';
    }
    return null;
  }

  void _applyPreset(_PresetOption preset) {
    HapticFeedback.lightImpact();
    setState(() {
      _baseUrlController.text = preset.baseUrl;
      _modelController.text = preset.model;
      _testSuccessInfo = null;
      _testErrorInfo = null;
    });
    showSnackBar('已套用 ${preset.name} 预设');
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);
    try {
      await AiRuleSettingsService.instance.save(_config);
      if (!mounted) return;
      showSnackBar('AI 模型配置已保存');
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) showSnackBar('保存失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    if (_testing || !(_formKey.currentState?.validate() ?? false)) return;

    final baseUrlText = _baseUrlController.text.trim();
    final isLocal =
        baseUrlText.contains('localhost') || baseUrlText.contains('127.0.0.1');
    if (!isLocal && _apiKeyController.text.trim().isEmpty) {
      HapticFeedback.mediumImpact();
      showSnackBar('云端服务需要身份凭证，请先输入 API Key', isError: true);
      setState(() {
        _testErrorInfo = '云端服务通常需要 API Key 才能验证身份与计费。请先填写您的 API Key。';
      });
      return;
    }

    HapticFeedback.lightImpact();
    setState(() {
      _testing = true;
      _testSuccessInfo = null;
      _testErrorInfo = null;
    });
    final stopwatch = Stopwatch()..start();
    final service = AiRuleAuthoringService();
    try {
      await service.testConnection(_config);
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _testSuccessInfo =
            '握手成功！模型响应耗时 ${stopwatch.elapsedMilliseconds}ms，OpenAI 兼容协议支持正常。';
      });
      showSnackBar('模型连接成功');
    } catch (error) {
      stopwatch.stop();
      if (!mounted) return;
      final errorStr = error.toString();
      String hint = '';
      if (errorStr.contains('400')) {
        hint =
            '\n提示：HTTP 400 代表请求被服务端拒绝。请检查：\n1. API Key 是否填写正确且有效\n2. 模型名称在该服务商是否存在\n3. 账户是否开通该模型权限或有余额';
      } else if (errorStr.contains('401')) {
        hint = '\n提示：HTTP 401 代表身份验证失败，请核对 API Key 是否正确。';
      } else if (errorStr.contains('404')) {
        hint = '\n提示：HTTP 404 代表接口地址不存在，请核对 Base URL（通常以 /v1 结尾）。';
      }
      setState(() {
        _testErrorInfo = '$errorStr$hint';
      });
      showSnackBar('连接失败：$error', isError: true);
    } finally {
      service.cancel();
      if (mounted) setState(() => _testing = false);
    }
  }

  Widget _buildHeroBanner(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = context.primaryColor;

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: isDark ? 0.12 : 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: primary.withValues(alpha: isDark ? 0.25 : 0.18),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.auto_awesome_rounded, color: primary, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'OpenAI 兼容大模型接入',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'AniBaka 的 AI 规则编写与源修复功能依赖具有代码分析能力的 LLM。API Key 仅存储于系统安全加密区，所有推理数据直连服务商。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.72)
                        : Colors.black.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetChips(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = context.primaryColor;

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: context.reduceMotion
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bolt_rounded, size: 18, color: primary),
              const SizedBox(width: 6),
              Text(
                '快捷预设（点击一键填入地址与模型）',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presets.map((preset) {
              final isMatch =
                  _baseUrlController.text.trim() == preset.baseUrl &&
                  _modelController.text.trim() == preset.model;
              return Material(
                color: isMatch
                    ? primary.withValues(alpha: 0.15)
                    : (isDark
                          ? const Color(0xFF2C2C2E)
                          : const Color(0xFFF2F2F7)),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: () => _applyPreset(preset),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          preset.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isMatch
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: isMatch
                                ? primary
                                : (isDark ? Colors.white : Colors.black87),
                          ),
                        ),
                        if (preset.badge != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              preset.badge!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    String? Function(String?)? validator,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    bool isLast = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, 16, isLast ? 16 : 6),
      child: TextFormField(
        controller: controller,
        validator: validator,
        obscureText: obscureText,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, size: 20),
          suffixIcon: suffixIcon,
          filled: true,
          fillColor: isDark
              ? const Color(0xFF2C2C2E).withValues(alpha: 0.6)
              : const Color(0xFFF7F7F9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: isDark ? Colors.white12 : Colors.black12,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: context.primaryColor, width: 1.6),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildTestResultCard(BuildContext context) {
    if (_testSuccessInfo == null && _testErrorInfo == null && !_testing) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = context.primaryColor;
    final errorColor = context.colorScheme.error;

    if (_testing) {
      return Container(
        margin: const EdgeInsets.only(top: 18),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '正在与端点进行握手测试，请稍候...',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_testSuccessInfo != null) {
      return Container(
        margin: const EdgeInsets.only(top: 18),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF10B981).withValues(alpha: isDark ? 0.16 : 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF10B981).withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.check_circle_rounded,
              color: Color(0xFF10B981),
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _testSuccessInfo!,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: isDark
                      ? const Color(0xFFA7F3D0)
                      : const Color(0xFF065F46),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_testErrorInfo != null) {
      return Container(
        margin: const EdgeInsets.only(top: 18),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: errorColor.withValues(alpha: isDark ? 0.16 : 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: errorColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, color: errorColor, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '模型握手测试失败',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: errorColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _testErrorInfo!,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Form(
        key: _formKey,
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            const SettingsSliverAppBar(title: 'AI 规则编写'),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _buildHeroBanner(context),
                  _buildPresetChips(context),
                  const SettingsSectionHeader('服务商接入参数'),
                  SettingsGroup(
                    children: [
                      _buildField(
                        controller: _baseUrlController,
                        label: 'Base URL',
                        hint: 'https://api.openai.com/v1',
                        icon: Icons.link_rounded,
                        keyboardType: TextInputType.url,
                        validator: _validateBaseUrl,
                      ),
                      _buildField(
                        controller: _modelController,
                        label: '模型名称 (Model)',
                        hint: '例如 deepseek-chat 或 gpt-4o-mini',
                        icon: Icons.smart_toy_outlined,
                        validator: (value) =>
                            value?.trim().isEmpty == true ? '请输入模型名称' : null,
                      ),
                      _buildField(
                        controller: _apiKeyController,
                        label: 'API Key（本地服务可留空）',
                        hint: 'sk-...',
                        icon: Icons.key_rounded,
                        obscureText: _obscureKey,
                        isLast: true,
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setState(() => _obscureKey = !_obscureKey),
                          icon: Icon(
                            _obscureKey
                                ? Icons.visibility_rounded
                                : Icons.visibility_off_rounded,
                            size: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                  _buildTestResultCard(context),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _testing ? null : _test,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: _testing
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.wifi_tethering_rounded,
                                  size: 18,
                                ),
                          label: const Text('测试连通性'),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: _saving
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_rounded, size: 18),
                          label: const Text('保存配置'),
                        ),
                      ),
                    ],
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
