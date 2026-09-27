import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Keeps Windows tooltip anchors separate in scrolling semantics containers.
class PlatformTooltip extends StatelessWidget {
  const PlatformTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tooltip = Tooltip(message: message, child: child);
    if (defaultTargetPlatform != TargetPlatform.windows) return tooltip;

    // Flutter 3.44 can merge sibling OverlayPortal traversal parents and lose
    // the second anchor. Windows then rejects the orphaned overlay in AXTree.
    // Keep the boundary outside Tooltip so it includes the portal's anchor.
    // https://github.com/flutter/flutter/issues/182444
    return Semantics(container: true, child: tooltip);
  }
}
