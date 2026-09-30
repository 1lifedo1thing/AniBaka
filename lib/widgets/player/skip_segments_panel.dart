import 'dart:async';

import 'package:baka/api/api_config.dart';
import 'package:baka/api/bgm.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/models/skip_segment.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/utils/duration_utils.dart';
import 'package:baka/widgets/player/skip_segment_track.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'package:flutter/material.dart';

class SkipSegmentsPanel extends StatefulWidget {
  const SkipSegmentsPanel({required this.controller, super.key});
  final PlaybackController controller;
  static Future<void> show(
    BuildContext context,
    PlaybackController controller,
  ) => showPlayerSettingsPanel(
    context,
    SkipSegmentsPanel(controller: controller),
  );

  @override
  State<SkipSegmentsPanel> createState() => _SkipSegmentsPanelState();
}

class _SkipSegmentsPanelState extends State<SkipSegmentsPanel> {
  final _start = TextEditingController();
  final _end = TextEditingController();
  String _type = 'op';
  bool _busy = false;
  String? _draftKey;
  PlaybackController get ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _draftKey = ctrl.skipContext?.localKey;
    ctrl.skipData.addListener(_onEpisodeChanged);
    // The settings summary may still be mounted behind this route.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ctrl.refreshSkipSegments(force: true));
    });
  }

  void _onEpisodeChanged() {
    final key = ctrl.skipContext?.localKey;
    if (_draftKey == key) return;
    _draftKey = key;
    _start.clear();
    _end.clear();
  }

  @override
  void dispose() {
    ctrl.skipData.removeListener(_onEpisodeChanged);
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      showSnackBar('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  SkipSegment _draft() {
    final start = double.tryParse(_start.text);
    final end = double.tryParse(_end.text);
    if (start == null || end == null || !start.isFinite || !end.isFinite) {
      throw const FormatException('请输入有效的起止秒数');
    }
    final value = SkipSegment(
      id: 'local:$_type',
      type: _type,
      startMs: (start * 1000).round(),
      endMs: (end * 1000).round(),
      durationMs: ctrl.timeline.value.duration.inMilliseconds,
      origin: 'local',
      automatic: true,
      status: 'personal',
    );
    if (!value.valid) throw const FormatException('需要满足：0 ≤ 起点 < 终点 ≤ 视频时长');
    return value;
  }

  Future<void> _save({required bool share}) => _run(() async {
    final context = ctrl.skipContext;
    if (context == null) throw const FormatException('请先打开视频');
    final value = _draft();
    await ctrl.skipService.saveLocal(context, value);
    if (identical(ctrl.skipContext, context)) {
      await ctrl.refreshSkipSegments(force: true);
    }
    if (share) {
      if (!apiTransport.session.isLoggedIn) {
        throw const FormatException('已保存在本机；登录后可共享');
      }
      await ctrl.skipService.submit(context, value);
      if (identical(ctrl.skipContext, context)) {
        await ctrl.refreshSkipSegments(force: true);
      }
    }
    showSnackBar(share ? '已共享，其他用户确认后生效' : '已保存当前片源标注');
  });

  Future<void> _bind() async {
    final original = ctrl.skipContext;
    if (original == null) return;
    final subject = TextEditingController(
      text: original.subjectId?.toString() ?? '',
    );
    final episode = TextEditingController(
      text: original.episodeId?.toString() ?? '',
    );
    List<Map<String, dynamic>> choices = const [];
    String? error;
    bool busy = false;
    try {
      final route = DialogRoute<(int, int)>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('绑定 Bangumi 剧集'),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: subject,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '番剧条目 ID（/subject/ 后的数字）',
                      ),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              update(() {
                                busy = true;
                                error = null;
                              });
                              try {
                                final id = int.tryParse(subject.text) ?? 0;
                                if (id <= 0) {
                                  throw const FormatException('请输入条目 ID');
                                }
                                choices = await getBgmEpisodes(id);
                              } catch (e) {
                                error = '$e';
                              }
                              if (context.mounted) update(() => busy = false);
                            },
                      child: const Text('加载正篇剧集'),
                    ),
                    if (choices.isNotEmpty)
                      DropdownButtonFormField<int>(
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '选择剧集'),
                        items: [
                          for (final item in choices)
                            DropdownMenuItem(
                              value: (item['id'] as num).toInt(),
                              child: Text(
                                '${item['sort']} · ${item['name_cn'] ?? item['name'] ?? ''}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (id) {
                          episode.text = '$id';
                        },
                      ),
                    TextField(
                      controller: episode,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '剧集 ID（/ep/ 后的数字，支持 SP）',
                      ),
                    ),
                    if (error != null) Text(error!),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          final s = int.tryParse(subject.text) ?? 0,
                              e = int.tryParse(episode.text) ?? 0;
                          if (s <= 0 || e <= 0) {
                            throw const FormatException('请输入有效 ID');
                          }
                          final info = await getBgmEpisode(e);
                          if (info['subject_id'] != s) {
                            throw const FormatException('该剧集不属于所选番剧');
                          }
                          if (context.mounted) Navigator.pop(context, (s, e));
                        } catch (e) {
                          if (context.mounted) {
                            update(() {
                              error = '$e';
                              busy = false;
                            });
                          }
                        }
                      },
                child: const Text('绑定'),
              ),
            ],
          ),
        ),
      );
      final binding = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      await route.completed;
      if (mounted && binding != null && identical(original, ctrl.skipContext)) {
        final bound = original.bind(binding.$1, binding.$2);
        await ctrl.skipService.bind(bound);
        if (identical(original, ctrl.skipContext)) {
          ctrl.setSkipContext(bound);
          await ctrl.refreshSkipSegments(force: true);
        }
      }
    } finally {
      subject.dispose();
      episode.dispose();
    }
  }

  String _time(int ms) => Duration(milliseconds: ms).toTimeString();

  Widget _segment(SkipContext context, SkipSegment segment) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${segment.label}  ${_time(segment.startMs)} → ${_time(segment.endMs)}',
          style: TextStyle(
            color: SkipSegmentColors.forType(segment.type),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${switch (segment.origin) {
            'local' => '本机',
            'aniskip' => 'AniSkip',
            _ => '社区',
          }} · '
          '${segment.automatic ? '可自动跳过' : '待确认'} · ${segment.confirms} 人确认 / ${segment.reports} 人报错',
          style: const TextStyle(
            color: Color(0xFFD4DCE5),
            fontSize: 12,
            height: 1.5,
          ),
        ),
        Wrap(
          spacing: 6,
          children: [
            TextButton(
              onPressed: ctrl.canControlPlayback && !context.isFirstEpisode
                  ? () => ctrl.previewSkipSegment(segment)
                  : null,
              child: const Text('手动跳过'),
            ),
            TextButton(
              onPressed: () => setState(() {
                _type = segment.type;
                _start.text = (segment.startMs / 1000).toStringAsFixed(3);
                _end.text = (segment.endMs / 1000).toStringAsFixed(3);
              }),
              child: const Text('校正'),
            ),
            if (segment.origin != 'local') ...[
              for (final accurate in [true, false])
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          if (!apiTransport.session.isLoggedIn) {
                            throw const FormatException('请先登录再反馈');
                          }
                          await ctrl.skipService.feedback(
                            context,
                            segment,
                            accurate,
                          );
                          if (identical(context, ctrl.skipContext)) {
                            await ctrl.refreshSkipSegments(force: true);
                          }
                          showSnackBar('已提交反馈');
                        }),
                  child: Text(accurate ? '准确' : '有误'),
                ),
            ],
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PanelContainer(
    title: '片头片尾区间',
    child: ValueListenableBuilder<SkipData>(
      valueListenable: ctrl.skipData,
      builder: (context, data, _) {
        final current = data.context;
        final disabled = current == null
            ? <String>{}
            : ctrl.skipService.disabledTypes(current);
        return ListView(
          padding: playerPanelContentPadding(context),
          children: [
            const PanelSectionTitle('本集区间'),
            Text(
              data.message,
              style: const TextStyle(
                color: Color(0xFFD4DCE5),
                fontSize: 12,
                height: 1.5,
              ),
            ),
            if (current != null) ...[
              Text(current.bound ? '已绑定 Bangumi 剧集' : '尚未绑定剧集'),
              Wrap(
                children: [
                  TextButton(
                    onPressed: _busy ? null : _bind,
                    child: const Text('绑定 / 更正剧集'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () =>
                              _run(() => ctrl.refreshSkipSegments(force: true)),
                    child: const Text('刷新'),
                  ),
                ],
              ),
              for (final segment in data.segments) _segment(current, segment),
              SizedBox(height: isCompactPlayerPanel(context) ? 12 : 24),
              const PanelSectionTitle('校正区间'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'op', label: Text('片头')),
                  ButtonSegment(value: 'ed', label: Text('片尾')),
                ],
                selected: {_type},
                onSelectionChanged: (value) =>
                    setState(() => _type = value.single),
              ),
              const SizedBox(height: 12),
              for (final field in [(_start, '起点'), (_end, '终点')])
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: field.$1,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: '${field.$2}（秒）',
                          filled: true,
                          fillColor: const Color(0x6630445B),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => field.$1.text =
                          (ctrl.timeline.value.position.inMilliseconds / 1000)
                              .toStringAsFixed(3),
                      child: Text('记录${field.$2}'),
                    ),
                  ],
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: ctrl.canControlPlayback
                        ? () => _run(() async {
                            final value = _draft();
                            await ctrl.seek(
                              Duration(milliseconds: value.startMs),
                            );
                            await ctrl.play();
                          })
                        : null,
                    child: const Text('预览起点'),
                  ),
                  TextButton(
                    onPressed: ctrl.canControlPlayback
                        ? () => _run(() async {
                            final value = _draft();
                            await ctrl.seek(
                              Duration(
                                milliseconds: (value.endMs - 3000).clamp(
                                  value.startMs,
                                  value.endMs,
                                ),
                              ),
                            );
                            await ctrl.play();
                          })
                        : null,
                    child: const Text('预览终点'),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : () => _save(share: false),
                    child: const Text('保存本机'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _save(share: true),
                    child: const Text('保存并共享'),
                  ),
                ],
              ),
              for (final type in ['op', 'ed'])
                PanelSwitchTile(
                  title: '当前片源禁用${type == 'op' ? '片头' : '片尾'}跳过',
                  value: disabled.contains(type),
                  onChanged: (value) => _run(() async {
                    await ctrl.skipService.disable(current, type, value);
                    if (identical(current, ctrl.skipContext)) {
                      await ctrl.refreshSkipSegments(force: true);
                    }
                  }),
                ),
              const SizedBox(height: 12),
              const Text(
                '标注仅适用于当前片源；共享后需另外两位用户确认。片尾终点应保留彩蛋与预告。',
                style: TextStyle(
                  color: Color(0xFFD4DCE5),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
            if (apiTransport.session.user.value.level & 8 != 0)
              TextButton(
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => const _SkipAdminDialog(),
                ),
                child: const Text('管理共享标注与映射'),
              ),
            if (_busy) const LinearProgressIndicator(),
          ],
        );
      },
    ),
  );
}

class _SkipAdminDialog extends StatefulWidget {
  const _SkipAdminDialog();
  @override
  State<_SkipAdminDialog> createState() => _SkipAdminDialogState();
}

class _SkipAdminDialogState extends State<_SkipAdminDialog> {
  List<Map<String, dynamic>> _rows = [];
  String? _error;
  bool _busy = false;
  final _fields = List.generate(4, (_) => TextEditingController());
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _load() => _run(() async {
    final json = await apiTransport.getData<Map<String, dynamic>>(
      '${ApiConfig.host}/api/v1/admin/skip-segments',
    );
    _rows = (json['segments'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  });
  Future<void> _run(Future<void> Function() action) async {
    if (!mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('共享标注管理'),
    content: SizedBox(
      width: 620,
      height: 520,
      child: ListView(
        children: [
          const Text('精确集数映射（拆分条目、SP 或跨季编号）'),
          for (var i = 0; i < 4; i++)
            TextField(
              controller: _fields[i],
              decoration: InputDecoration(
                labelText: [
                  'Bangumi 条目 ID',
                  'Bangumi 剧集 ID',
                  'MAL ID',
                  'MAL 集数',
                ][i],
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await apiTransport.putData<Map<String, dynamic>>(
                      '${ApiConfig.host}/api/v1/admin/skip-mapping',
                      {
                        'bgm_id': int.tryParse(_fields[0].text),
                        'episode_id': int.tryParse(_fields[1].text),
                        'mal_id': int.tryParse(_fields[2].text),
                        'mal_episode': double.tryParse(_fields[3].text),
                      },
                    );
                    showSnackBar('已保存映射');
                  }),
            child: const Text('保存映射'),
          ),
          if (_error != null) Text(_error!),
          if (_busy) const LinearProgressIndicator(),
          for (final row in _rows)
            ListTile(
              title: Text(
                '番剧 ${row['bgm_id']} / 集 ${row['episode_id']} · ${row['type']}',
              ),
              subtitle: Text(
                '${row['start_ms']}–${row['end_ms']} ms · ${row['status']}\n${row['confirms']} 确认 / ${row['reports']} 报错',
              ),
              trailing: PopupMenuButton<String>(
                enabled: !_busy,
                onSelected: (value) async {
                  await _run(() async {
                    await apiTransport.putData<Map<String, dynamic>>(
                      '${ApiConfig.host}/api/v1/admin/skip-segments/${row['id']}',
                      {'status': value},
                    );
                  });
                  await _load();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'approved', child: Text('确认')),
                  PopupMenuItem(value: 'rejected', child: Text('撤销')),
                  PopupMenuItem(value: 'candidate', child: Text('恢复待确认')),
                ],
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: _busy ? null : _load, child: const Text('刷新')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
