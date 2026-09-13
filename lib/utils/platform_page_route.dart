import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Builds a route with Android predictive back and iOS edge-swipe back.
///
/// Custom [PageRouteBuilder] transitions bypass [PageTransitionsTheme].
///
/// On Android a plain page uses [MaterialPageRoute], which is what predictive
/// back and the theme's timings are wired into; iOS uses [CupertinoPageRoute].
/// Desktop keeps the [PageRouteBuilder] with no transition, because a cover
/// there is animated by its own [Hero] flight rather than by a page transition.
/// Explicit instant routes (fullscreen video) and custom surfaces keep their
/// [PageRouteBuilder] configuration on every platform.
PageRoute<T> platformPageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  Duration transitionDuration = const Duration(milliseconds: 300),
  Duration? reverseTransitionDuration,
  RouteTransitionsBuilder? transitionsBuilder,
  bool maintainState = true,
  bool fullscreenDialog = false,
  bool allowSnapshotting = true,
  bool opaque = true,
  Color? barrierColor,
  String? barrierLabel,
  bool barrierDismissible = false,
}) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return CupertinoPageRoute<T>(
      builder: builder,
      settings: settings,
      maintainState: maintainState,
      fullscreenDialog: fullscreenDialog,
      allowSnapshotting: allowSnapshotting,
      barrierDismissible: barrierDismissible,
    );
  }

  final instant =
      transitionDuration == Duration.zero &&
      (reverseTransitionDuration == null ||
          reverseTransitionDuration == Duration.zero);
  if (!instant &&
      opaque &&
      barrierColor == null &&
      barrierLabel == null &&
      defaultTargetPlatform == TargetPlatform.android) {
    return MaterialPageRoute<T>(
      builder: builder,
      settings: settings,
      maintainState: maintainState,
      fullscreenDialog: fullscreenDialog,
      allowSnapshotting: allowSnapshotting,
      barrierDismissible: barrierDismissible,
    );
  }

  return PageRouteBuilder<T>(
    settings: settings,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionDuration: transitionDuration,
    reverseTransitionDuration: reverseTransitionDuration ?? transitionDuration,
    transitionsBuilder:
        transitionsBuilder ??
        (context, animation, secondaryAnimation, child) => child,
    maintainState: maintainState,
    fullscreenDialog: fullscreenDialog,
    allowSnapshotting: allowSnapshotting,
    opaque: opaque,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    barrierDismissible: barrierDismissible,
  );
}
