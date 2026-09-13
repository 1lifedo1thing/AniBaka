import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Rebuilds only when the selected immutable value changes (using ==).
class ValueSelector<T, S> extends StatefulWidget {
  const ValueSelector({
    required this.valueListenable,
    required this.select,
    required this.builder,
    super.key,
  });

  final ValueListenable<T> valueListenable;
  final S Function(T) select;
  final Widget Function(BuildContext, S) builder;

  @override
  State<ValueSelector<T, S>> createState() => _ValueSelectorState<T, S>();
}

class _ValueSelectorState<T, S> extends State<ValueSelector<T, S>> {
  late S _value;

  @override
  void initState() {
    super.initState();
    _value = widget.select(widget.valueListenable.value);
    widget.valueListenable.addListener(_update);
  }

  void _update() {
    final next = widget.select(widget.valueListenable.value);
    if (next != _value) setState(() => _value = next);
  }

  @override
  void didUpdateWidget(covariant ValueSelector<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valueListenable != widget.valueListenable) {
      oldWidget.valueListenable.removeListener(_update);
      widget.valueListenable.addListener(_update);
    }
    _value = widget.select(widget.valueListenable.value);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);

  @override
  void dispose() {
    widget.valueListenable.removeListener(_update);
    super.dispose();
  }
}
