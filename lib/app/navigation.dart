import 'package:baka/instance.dart';
import 'package:baka/models/playback_request.dart';
import 'package:flutter/material.dart';
import 'package:baka/pages/anime_detail/anime_detail_page.dart';
import 'package:baka/pages/player/player_page.dart';
import 'package:baka/pages/search/search_page.dart';
import 'package:baka/pages/source/source_management_page.dart';
import 'package:baka/utils/platform_page_route.dart';
import 'package:baka/utils/card_page_route.dart';

/// 集中管理页面导航，解耦 Widget 对具体 Page 的直接依赖。
class NavigationService {
  NavigationService._();

  static PageRoute<void> _pageRoute(Widget page) =>
      platformPageRoute<void>(builder: (_) => page);

  /// 导航到番剧详情页，并保留当前页面以便正常返回。
  ///
  /// [cardContext] and [cardPreview] describe the card that was tapped. They
  /// drive the card route on touch platforms and are ignored on desktop, where
  /// the cover is animated by its own Hero flight instead.
  static void toDetail(
    BuildContext context,
    Map data, {
    int? posIndex,
    bool autoMatch = false,
    BuildContext? cardContext,
    Widget? cardPreview,
  }) {
    // Detail and later playback enrich their route data independently. Keep
    // those mutations away from the source card while retaining its episode.
    final routeData = data.cast<String, dynamic>();
    if (posIndex != null) routeData['currPlayIndex'] = posIndex;
    final page = autoMatch
        ? PlayerPage(
            request: PlaybackRequest.fromMap(routeData),
            posIndex: posIndex,
            autoMatch: true,
          )
        : AnimeDetailPage(data: routeData);
    final navigator = Navigator.of(context);
    Rect? sourceRect() {
      if (cardContext == null || !cardContext.mounted) return null;
      final box = cardContext.findRenderObject();
      final overlay = navigator.overlay?.context.findRenderObject();
      if (box is! RenderBox ||
          !box.attached ||
          !box.hasSize ||
          overlay is! RenderBox ||
          !overlay.hasSize) {
        return null;
      }
      final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
      if (!rect.isFinite ||
          rect.isEmpty ||
          !(Offset.zero & overlay.size).overlaps(rect)) {
        return null;
      }
      return rect;
    }

    final origin = sourceRect();
    final preview = cardPreview;
    final PageRoute<void> route;
    // Desktop keeps the Hero flight between the card and the detail header, so
    // the surface is only built where the cover has no flight of its own.
    if (origin != null &&
        preview != null &&
        !autoMatch &&
        !Instances.isDesktopPlatform) {
      route = CardPageRoute<void>(
        builder: (_) => page,
        sourceRect: origin,
        resolveSourceRect: sourceRect,
        preview: preview,
        reduceMotion: MediaQuery.disableAnimationsOf(context),
      );
    } else {
      route = _pageRoute(page);
    }
    navigator.push(route);
  }

  static void toPlayer(
    BuildContext context,
    Map data, {
    int? posIndex,
    bool popFirst = false,
    bool fade = false,
    bool autoMatch = true,
  }) {
    final navigator = Navigator.of(context);
    if (popFirst) navigator.pop();
    // Playback selection mutates the page data as episodes and lines change.
    // Do not leak that state back into a detail page or search result card.
    final routeData = data.cast<String, dynamic>();
    final PageRoute<void> route = fade
        ? platformPageRoute<void>(
            builder: (_) => PlayerPage(
              request: PlaybackRequest.fromMap(routeData),
              posIndex: posIndex,
              autoMatch: autoMatch,
            ),
            transitionsBuilder: (_, anim, _, child) =>
                FadeTransition(opacity: anim, child: child),
            transitionDuration: const Duration(milliseconds: 300),
          )
        : _pageRoute(
            PlayerPage(
              request: PlaybackRequest.fromMap(routeData),
              posIndex: posIndex,
              autoMatch: autoMatch,
            ),
          );
    navigator.push(route);
  }

  /// 导航到搜索页面
  static void toSearch(
    BuildContext context, {
    String? keyword,
    int? initialSource,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchPage(k: keyword, initialSource: initialSource),
      ),
    );
  }

  /// 导航到源管理页面
  static void toSourceManagement(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SourceManagementPage()),
    );
  }
}
