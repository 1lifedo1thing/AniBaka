import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CardPageRoute<T> extends MaterialPageRoute<T> {
  CardPageRoute({
    required super.builder,
    required this.sourceRect,
    required this.preview,
    this.resolveSourceRect,
    this.reduceMotion = false,
  });

  /// The card's rect, in the window's coordinates.
  final Rect sourceRect;

  /// Reads the card's rect again when a transition starts later than the push,
  /// since the list behind it may have scrolled.
  final Rect? Function()? resolveSourceRect;

  /// The card the surface grows out of and collapses back onto.
  final Widget preview;

  final bool reduceMotion;

  @override
  Duration get transitionDuration =>
      Duration(milliseconds: reduceMotion ? 0 : 320);

  @override
  Duration get reverseTransitionDuration =>
      Duration(milliseconds: reduceMotion ? 0 : 280);

  // The card sits behind the surface and must stay where it is.
  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => null;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // The preview draws the same card, so this page must not fly its heroes.
    return HeroMode(
      enabled: false,
      child: super.buildPage(context, animation, secondaryAnimation),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion) return child;
    final Widget surface = _CardTransition(
      route: this,
      animation: animation,
      child: child,
    );
    if (Theme.of(context).platform != TargetPlatform.iOS) return surface;
    // Keep the iOS edge swipe. Settled animations leave Cupertino's own slide
    // out of the way, so only its gesture detector is added.
    return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
      this,
      context,
      kAlwaysCompleteAnimation,
      kAlwaysDismissedAnimation,
      surface,
    );
  }
}

class _CardTransition extends StatefulWidget {
  const _CardTransition({
    required this.route,
    required this.animation,
    required this.child,
  });

  final CardPageRoute<dynamic> route;
  final Animation<double> animation;
  final Widget child;

  @override
  State<_CardTransition> createState() => _CardTransitionState();
}

class _CardTransitionState extends State<_CardTransition>
    with WidgetsBindingObserver {
 
  static const Curve _curve = Curves.easeOutCubic;

  static const Interval _previewFade = Interval(0.08, 0.5);

  static const double _radius = 12;

  final SnapshotController _snapshot = SnapshotController();

  ValueNotifier<bool>? _gesture;
  ({double visual, double from, double to})? _fold;

  late Rect _rect = widget.route.sourceRect;
  late final Widget _preview = RepaintBoundary(
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: HeroMode(enabled: false, child: widget.route.preview),
      ),
    ),
  );

  Animation<double> get _animation => widget.animation;

  double get _progress {
    final value = _animation.value;
    final fold = _fold;
    if (fold != null) {
      final t = ((value - fold.from) / (fold.to - fold.from)).clamp(0.0, 1.0);
      return fold.visual + (fold.to - fold.visual) * _curve.transform(t);
    }

    if (widget.route.popGestureInProgress) return value;
    return _animation.status == AnimationStatus.reverse
        ? 1 - _curve.transform(1 - value)
        : _curve.transform(value);
  }

  bool get _moving =>
      _animation.status == AnimationStatus.forward ||
      _animation.status == AnimationStatus.reverse ||
      widget.route.navigator?.userGestureInProgress == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animation.addStatusListener(_onStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final gesture = widget.route.navigator?.userGestureInProgressNotifier;
    if (identical(gesture, _gesture)) return;
    _gesture?.removeListener(_syncSnapshot);
    _gesture = gesture;
    gesture?.addListener(_syncSnapshot);
    _syncSnapshot();
  }


  void _syncSnapshot() => _snapshot.allowSnapshotting = _moving;

  void _onStatus(AnimationStatus status) {
    final value = _animation.value;
    if (status == AnimationStatus.reverse &&
        _fold == null &&
        !widget.route.popGestureInProgress &&
        value > 0 &&
        value < 1) {
      // A collapse starting from a half open surface: hold the size on screen
      // and ease it down from there.
      _fold = (visual: _curve.transform(value), from: value, to: 0);
    }
    if (status == AnimationStatus.dismissed ||
        (status == AnimationStatus.completed && _fold?.to == 1)) {

      _fold = null;
    }
    if (status == AnimationStatus.reverse) _readRect();
    _syncSnapshot();
  }

  void _readRect() {
    final rect = widget.route.resolveSourceRect?.call();
    if (rect != null && rect != _rect) setState(() => _rect = rect);
  }

 
  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = widget.route;
    if (backEvent.isButtonEvent ||
        Theme.of(context).platform != TargetPlatform.android ||
        !route.isCurrent ||
        !route.popGestureEnabled) {
      return false;
    }
    _fold = null;
    _readRect();
    route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
  }

  @override
  void handleCancelBackGesture() {
    final value = _animation.value;
    _fold = value < 1 ? (visual: _progress, from: value, to: 1) : null;
    widget.route.handleCancelBackGesture();
  }

  @override
  void handleCommitBackGesture() {
    _fold = (visual: _progress, from: 1, to: 0);
    widget.route.handleCommitBackGesture();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animation.removeStatusListener(_onStatus);
    _gesture?.removeListener(_syncSnapshot);
    _snapshot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
 
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: _animation,
          builder: (context, _) => _surface(constraints.biggest),
        ),
      ),
    );
  }

  Widget _surface(Size window) {
    final progress = _progress;
    final alpha = 1 - _previewFade.transform(progress);
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fromRect(
          rect: Rect.lerp(_rect, Offset.zero & window, progress)!,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_radius * (1 - progress)),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _covered(
                  window,
                  SnapshotWidget(
                    controller: _snapshot,
                    mode: SnapshotMode.permissive,
                    autoresize: true,
                    child: widget.child,
                  ),
                ),
                if (alpha > 0)
                  _covered(
                    _rect.size,
                    Opacity(opacity: alpha, child: _preview),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _covered(Size size, Widget child) => FittedBox(
    fit: BoxFit.cover,
    alignment: Alignment.topCenter,
    child: SizedBox.fromSize(size: size, child: child),
  );
}
