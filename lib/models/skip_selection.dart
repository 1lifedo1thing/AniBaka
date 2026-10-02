import 'skip_segment.dart';

typedef SkipRange = ({int startMs, int endMs});

/// Drafts stay with their video while the controls move between screen layouts.
class SkipSelection {
  SkipSelection({
    required this.context,
    required this.durationMs,
    required this.type,
    required Map<String, SkipRange> ranges,
    Set<String> changed = const {},
    this.saving = false,
  }) : ranges = Map.unmodifiable(ranges),
       changed = Set.unmodifiable(changed);

  final SkipContext context;
  final int durationMs;
  final String type;
  final Map<String, SkipRange> ranges;
  final Set<String> changed;
  final bool saving;
  SkipRange get range => ranges[type]!;
  String get label => type == 'op' ? '片头' : '片尾';

  SkipSelection copyWith({
    String? type,
    Map<String, SkipRange>? ranges,
    Set<String>? changed,
    bool? saving,
  }) => SkipSelection(
    context: context,
    durationMs: durationMs,
    type: type ?? this.type,
    ranges: ranges ?? this.ranges,
    changed: changed ?? this.changed,
    saving: saving ?? this.saving,
  );

  SkipSegment segment(String type) => SkipSegment(
    id: 'local:$type',
    type: type,
    startMs: ranges[type]!.startMs,
    endMs: ranges[type]!.endMs,
    durationMs: durationMs,
    origin: 'local',
    automatic: true,
    status: 'personal',
  );
}
