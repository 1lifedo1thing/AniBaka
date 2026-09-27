import '../support/app_dependencies.dart';
import 'dart:async';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/view.dart';
import 'package:baka/widgets/baka_player/widgets/player_info_hud.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/platform/windows/windows_episode_list.dart';
import 'package:baka/widgets/platform/windows/windows_player_layout.dart';
import 'package:baka/widgets/player/player_tab.dart';
// ignore: depend_on_referenced_packages
import 'package:bitsdojo_window_platform_interface/bitsdojo_window_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Native window chrome is not available in the widget test runner.

class _TestWindow extends NotImplementedWindow {
  @override
  bool get isMaximized => false;
  @override
  double get titleBarHeight => 32;
  @override
  double get scaleFactor => 1;
}

class _TestWindowPlatform extends BitsdojoWindowPlatform {
  @override
  DesktopWindow get appWindow => _TestWindow();
}

class _Player extends PlaybackController {
  int calls = 0;
  Completer<PlaybackTechnicalInfo>? pending;
  @override
  Future<PlaybackTechnicalInfo> loadTechnicalInfo() {
    calls++;
    return pending?.future ??
        Future.value(const PlaybackTechnicalInfo(width: 1920, height: 1080));
  }
}

Widget _host(Widget child) => MaterialApp(home: Material(child: child));

void main() {
  group('seek', () {
    testWidgets('progress bar drag seeks to the finger position', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      configureTestServices();
      Instances.isTV = false;

      final controller = PlaybackController();
      controller.timeline.value = controller.timeline.value.copyWith(
        duration: const Duration(minutes: 24),
        position: const Duration(minutes: 20),
      );
      controller.setControlsVisible(true);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BakaPlayer(controller: controller, full: true)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final progressBarFinder = find.byType(ProgressBar);
      expect(progressBarFinder, findsOneWidget);
      final rect = tester.getRect(progressBarFinder);
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * 0.5, rect.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(
        Offset(rect.left + rect.width * 0.5, rect.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));

      // 拖动条按手指位置 seek，而不是跳到结尾。
      expect(controller.timeline.value.position.inMinutes, 12);
      await controller.dispose();
    });
  });

  group('tabs', () {
    setUp(() {
      final previous = BitsdojoWindowPlatform.instance;
      BitsdojoWindowPlatform.instance = _TestWindowPlatform();
      addTearDown(() => BitsdojoWindowPlatform.instance = previous);
    });
    testWidgets('desktop tabs retain comments, draft and episode list state', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      var commentRequests = 0;
      apiTransport = ApiTransport(
        session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
        client: MockClient((request) async {
          if (request.url.path == '/comments') commentRequests++;
          return http.Response('{"data":[]}', 200);
        }),
        version: 'test',
      );
      addTearDown(apiTransport.close);
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = PlaybackController();
      final danmaku = DanmakuController();
      final follow = ValueNotifier(false);
      final commentKey = GlobalKey<CIslandCommentWidgetState>();
      addTearDown(danmaku.dispose);
      addTearDown(follow.dispose);
      Widget layout({int postId = 17, int episodeIndex = 0}) => MaterialApp(
        home: WindowsPlayerLayout(
          data: {'id': postId, 'title': 'Tab regression'},
          torrent: TorrentService(),
          videoList: const [PlaybackEpisode(title: '第1集', lines: [])],
          currPlayIndex: episodeIndex,
          currUrl: 1,
          inited: false,
          controller: controller,
          danmakuController: danmaku,
          followNotifier: follow,
          sourceName: '测试源',
          lineName: null,
          onSourceTap: () {},
          commentKey: commentKey,
          onEpisodeChanged: (_) {},
          onCastPressed: () {},
          onWatchPartyPressed: () {},
          onPickEpisode: () {},
          onFullScreenChanged: (_) {},
          onUrlChanged: (_) {},
          onCommentLinkTap: (_, _, _) {},
          onDownloadPressed: () {},
          onFollowPressed: () {},
          onAiRepair: () {},
        ),
      );
      await tester.pumpWidget(layout());
      await tester.pump(const Duration(milliseconds: 300));
      expect(commentRequests, 0, reason: 'Comments load only on first visit');
      final episodeState = tester.state(find.byType(WindowsEpisodeList));
      await tester.enterText(find.byType(TextField), '第1集');
      State? firstCommentState;
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('互动评论'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        firstCommentState ??= commentKey.currentState;
        if (i == 0) {
          await tester.enterText(find.byType(TextField), '未发送的评论');
        }
        await tester.tap(find.text('简介'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
      // Fixed workload: four visits, no network latency or native playback.
      debugPrint('Four comment visits: $commentRequests requests');
      expect(commentRequests, 1);
      expect(tester.state(find.byType(WindowsEpisodeList)), same(episodeState));
      expect(find.text('第1集').evaluate().length, greaterThan(0));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '第1集',
      );
      await tester.tap(find.text('互动评论'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(commentKey.currentState, same(firstCommentState));
      expect(find.text('未发送的评论'), findsOneWidget);
      await tester.tap(find.text('简介'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(layout(postId: 18));
      await tester.pump();
      await tester.tap(find.text('互动评论'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(commentKey.currentState!.widget.postId, 18);
      expect(
        commentRequests,
        2,
        reason: 'A changed post still reloads comments',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    });

    testWidgets('mobile tab swipe retains scroll and accepts new content', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      Widget layout(String title) => MaterialApp(
        home: DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              bottom: const TabBar(
                tabs: [
                  Tab(text: '选集'),
                  Tab(text: '评论'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                PlayerTab(
                  child: ListView.builder(
                    controller: scroll,
                    itemExtent: 60,
                    itemCount: 100,
                    itemBuilder: (_, i) => Text('$title $i'),
                  ),
                ),
                const Center(child: Text('评论内容')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(layout('原剧集'));
      await tester.drag(find.byType(ListView), const Offset(0, -480));
      await tester.pumpAndSettle();
      final offset = scroll.offset;
      final listState = tester.state(find.byType(Scrollable).last);
      await tester.drag(find.byType(TabBarView), const Offset(-800, 0));
      await tester.pumpAndSettle();
      expect(find.text('评论内容'), findsOneWidget);
      await tester.pumpWidget(layout('新剧集'));
      await tester.tap(find.text('选集'));
      await tester.pumpAndSettle();
      expect(scroll.offset, offset);
      expect(tester.state(find.byType(Scrollable).last), same(listState));
      expect(find.textContaining('新剧集'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('diagnostics lifecycle', () {
    testWidgets('slow poll does not overlap or update disposed HUD', (
      tester,
    ) async {
      final player = _Player()..pending = Completer();
      await tester.pumpWidget(
        _host(PlayerInfoHud(controller: player, onClose: () {})),
      );
      await tester.pump(const Duration(seconds: 6));
      expect(player.calls, 1);
      await tester.pumpWidget(const SizedBox());
      player.pending!.complete(const PlaybackTechnicalInfo());
      await tester.pump();
      expect(tester.takeException(), isNull);
      await player.dispose();
    });
  });
}
