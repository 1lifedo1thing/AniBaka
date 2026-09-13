import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Keep the last decoded image until its replacement is ready. The initial
/// cover uses exactly the same memory-cache key as PostCard's 300 px image.
class AnimeDetailBackground extends StatefulWidget {
  const AnimeDetailBackground({
    required this.coverUrl,
    required this.backgroundUrl,
    required this.loadBackground,
    required this.cacheWidth,
    super.key,
  });

  final String coverUrl;
  final String backgroundUrl;
  final bool loadBackground;
  final int cacheWidth;

  static ImageProvider _networkImage(String url, int width) =>
      ResizeImage.resizeIfNeeded(width, null, CachedNetworkImageProvider(url));

  @override
  State<AnimeDetailBackground> createState() => _AnimeDetailBackgroundState();
}

class _AnimeDetailBackgroundState extends State<AnimeDetailBackground> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _image;
  ImageInfo? _readyImage;
  (String, int)? _requested;
  String? _failedCover;
  ModalRoute<dynamic>? _route;
  Animation<double>? _animation;

  bool get _canDisplay =>
      _route == null ||
      (_route!.isCurrent &&
          !_route!.offstage &&
          (_animation == null || _animation!.isCompleted));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final animation = _route?.animation;
    if (!identical(animation, _animation)) {
      _animation?.removeStatusListener(_onAnimationStatus);
      _animation = animation;
      animation?.addStatusListener(_onAnimationStatus);
    }
    _showReadyImage();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant AnimeDetailBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    // While the surface is opening (and on mobile) the card's 300 px cover is
    // already decoded, so reuse it. Once the desktop layout settles, show a
    // full-width image: the dedicated backdrop when the entry has one,
    // otherwise the cover re-decoded at that same width instead of leaving a
    // 300 px thumbnail stretched over the header.
    final largeUrl = widget.backgroundUrl.isNotEmpty
        ? widget.backgroundUrl
        : widget.coverUrl;
    final useLarge =
        widget.loadBackground &&
        largeUrl.isNotEmpty &&
        largeUrl != _failedCover &&
        (_image != null ||
            widget.coverUrl.isEmpty ||
            _failedCover == widget.coverUrl);
    final url = useLarge ? largeUrl : widget.coverUrl;
    if (url.isEmpty) return;
    final request = (url, useLarge ? widget.cacheWidth : 300);
    if (_requested == request) return;
    _requested = request;
    _unsubscribe();
    _readyImage?.dispose();
    _readyImage = null;
    final stream = AnimeDetailBackground._networkImage(
      request.$1,
      request.$2,
    ).resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronous) {
        if (!mounted || _requested != request) {
          image.dispose();
          return;
        }
        if (synchronous || _canDisplay) {
          _display(image, synchronous: synchronous);
        } else {
          _readyImage?.dispose();
          _readyImage = image;
        }
      },
      onError: (Object error, StackTrace? stack) {
        // A missing/failed backdrop must not erase a working cover or backdrop.
        if (mounted && _requested == request && !useLarge) {
          _failedCover = url;
          _resolve();
        }
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _display(ImageInfo image, {bool synchronous = false}) {
    void update() {
      _image?.dispose();
      _image = image;
    }

    if (synchronous) {
      update();
    } else {
      setState(update);
    }
    _resolve();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _showReadyImage();
  }

  void _showReadyImage() {
    final image = _readyImage;
    if (image == null || !_canDisplay) return;
    _readyImage = null;
    _display(image);
  }

  void _unsubscribe() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _unsubscribe();
    _animation?.removeStatusListener(_onAnimationStatus);
    _image?.dispose();
    _readyImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: RawImage(
      image: _image?.image,
      scale: _image?.scale ?? 1,
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      filterQuality: FilterQuality.low,
    ),
  );
}
