import 'package:flutter/widgets.dart';

/// TabBarView lazily mounts each page; retain it after the first visit.
class PlayerTab extends StatefulWidget {
  const PlayerTab({required this.child, super.key});

  final Widget child;

  @override
  State<PlayerTab> createState() => _PlayerTabState();
}

class _PlayerTabState extends State<PlayerTab>
    with AutomaticKeepAliveClientMixin<PlayerTab> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
