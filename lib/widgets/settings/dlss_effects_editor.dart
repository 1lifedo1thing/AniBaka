import 'package:flutter/material.dart';
import 'package:baka/services/playback/dlss_global_playback.dart';

class DlssEffectsEditor extends StatefulWidget {
  const DlssEffectsEditor({super.key});

  @override
  State<DlssEffectsEditor> createState() => _DlssEffectsEditorState();
}

class _DlssEffectsEditorState extends State<DlssEffectsEditor> {
  late DlssPlaybackEffects _lastApplied;
  late double _intensity;
  late double _sharpness;
  late int _maxHeight;
  late bool _superResolution;
  late bool _frameGeneration;
  late bool _neuralRendering;
  late bool _comparison;

  @override
  void initState() {
    super.initState();
    _lastApplied = DlssGlobalPlayback.instance.effects;
    _load(_lastApplied);
    DlssGlobalPlayback.instance.addListener(_sync);
  }

  void _load(DlssPlaybackEffects effects) {
    _intensity = effects.intensity;
    _sharpness = effects.sharpness;
    _maxHeight = effects.maxHeight;
    _superResolution = effects.superResolution;
    _frameGeneration = effects.frameGeneration;
    _neuralRendering = effects.neuralRendering;
    _comparison = effects.comparison;
  }

  bool _matches(DlssPlaybackEffects effects) =>
      _intensity == effects.intensity &&
      _sharpness == effects.sharpness &&
      _maxHeight == effects.maxHeight &&
      _superResolution == effects.superResolution &&
      _neuralRendering == effects.neuralRendering &&
      _comparison == effects.comparison &&
      _frameGeneration == effects.frameGeneration;

  void _sync() {
    setState(() {
      final current = DlssGlobalPlayback.instance.effects;
      if (!identical(current, _lastApplied)) {
        if (_matches(_lastApplied)) _load(current);
        _lastApplied = current;
      }
    });
  }

  @override
  void dispose() {
    DlssGlobalPlayback.instance.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = DlssGlobalPlayback.instance;
    final changed =
        _intensity != service.effects.intensity ||
        _sharpness != service.effects.sharpness ||
        _maxHeight != service.effects.maxHeight ||
        _superResolution != service.effects.superResolution ||
        _neuralRendering != service.effects.neuralRendering ||
        _comparison != service.effects.comparison ||
        _frameGeneration != service.effects.frameGeneration;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('全局播放效果', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('NR 神经改绘'),
              subtitle: const Text(
                '默认关闭，直接将原画送入 NVIDIA 超分；开启后先改绘，可能改变线条、纹理和颜色。',
              ),
              value: _neuralRendering,
              onChanged: service.busy
                  ? null
                  : (value) => setState(() => _neuralRendering = value),
            ),
            Text('NR 重建强度：${_intensity.toStringAsFixed(2)}'),
            Slider(
              value: _intensity,
              min: .1,
              max: 2,
              divisions: 38,
              label: _intensity.toStringAsFixed(2),
              onChanged: service.busy || !_neuralRendering
                  ? null
                  : (value) => setState(() => _intensity = value),
            ),
            const Text('强度越高，对原画的改动越明显。默认 0.70。'),
            const SizedBox(height: 16),
            Text('输出锐化：${(_sharpness * 100).round()}%'),
            Slider(
              value: _sharpness,
              divisions: 20,
              label: '${(_sharpness * 100).round()}%',
              onChanged: service.busy
                  ? null
                  : (value) => setState(() => _sharpness = value),
            ),
            const Text('按局部对比度锐化，限制轮廓光晕并抑制细小噪点；0% 关闭。锐化不会恢复片源中缺失的细节。'),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: _maxHeight,
              key: ValueKey(_maxHeight),
              decoration: const InputDecoration(labelText: '处理分辨率上限'),
              items: const [
                DropdownMenuItem(
                  value: 720,
                  child: Text('1280 × 720 · 降低处理负担'),
                ),
                DropdownMenuItem(
                  value: 1080,
                  child: Text('1920 × 1080 · 保留更多输入细节'),
                ),
              ],
              onChanged: service.busy
                  ? null
                  : (value) {
                      if (value != null) setState(() => _maxHeight = value);
                    },
            ),
            const SizedBox(height: 8),
            const Text('超出上限的画面先按比例缩小；较小片源保持输入尺寸。'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('NVIDIA 2 倍超分辨率'),
              subtitle: const Text('宽高各放大 2 倍。窗口小于输出尺寸时会缩小显示，差异可能不明显。'),
              value: _superResolution,
              onChanged: service.busy
                  ? null
                  : (value) => setState(() => _superResolution = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('NVIDIA 帧生成'),
              subtitle: const Text('尝试在相邻画面间插入一帧，实际显示数量取决于处理速度。'),
              value: _frameGeneration,
              onChanged: service.busy
                  ? null
                  : (value) => setState(() => _frameGeneration = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('左右画质对比'),
              subtitle: const Text(
                '左侧保持原帧，右侧显示 NVIDIA 增强与插帧，两侧分别统计更新帧率。只比较画质时可关闭帧生成、将锐化设为 0%。',
              ),
              value: _comparison,
              onChanged: service.busy
                  ? null
                  : (value) => setState(() => _comparison = value),
            ),
            const Text(
              '保留细节请用 1080p 上限，720p 会先缩小较大的片源。超分开关或处理尺寸变化需要重新初始化；NR 仅在开启时加载，关闭后释放模型。播放器开关保留当前模型以便快速恢复，关闭实验室总开关可释放显存。',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: service.busy || !changed
                      ? null
                      : () async {
                          final saved = await service.applyEffects(
                            DlssPlaybackEffects(
                              intensity: _intensity,
                              sharpness: _sharpness,
                              maxHeight: _maxHeight,
                              superResolution: _superResolution,
                              frameGeneration: _frameGeneration,
                              neuralRendering: _neuralRendering,
                              comparison: _comparison,
                            ),
                          );
                          if (!context.mounted || !saved) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                service.enabled && service.playbackEnabled
                                    ? '效果已应用并保存'
                                    : '效果已保存，开启全局增强后生效',
                              ),
                            ),
                          );
                        },
                  child: Text(
                    service.enabled && service.playbackEnabled
                        ? '应用效果'
                        : '保存效果',
                  ),
                ),
                TextButton(
                  onPressed: service.busy
                      ? null
                      : () =>
                            setState(() => _load(const DlssPlaybackEffects())),
                  child: const Text('恢复默认值'),
                ),
                if (changed) const Text('有尚未应用的修改'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
