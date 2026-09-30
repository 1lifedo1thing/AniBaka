import '../support/app_dependencies.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/skip_segment.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/widgets/baka_player/widgets/player_prompts.dart';
import 'package:baka/widgets/player/skip_segment_track.dart';
import 'package:baka/widgets/player/skip_segments_panel.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'package:baka/pages/setting/player_settings_page.dart';
import 'package:baka/pages/setting/subtitle_settings_page.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/services/playback/danmaku_controller.dart';
import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/view.dart';
import 'package:baka/widgets/comment/comment_widget.dart';
import 'package:baka/widgets/platform/windows/windows_episode_list.dart';
import 'package:baka/widgets/platform/windows/windows_player_layout.dart';
import 'package:baka/widgets/player/player_tab.dart';
import 'package:baka/widgets/episode/episode_widgets.dart';
// ignore: depend_on_referenced_packages
import 'package:bitsdojo_window_platform_interface/bitsdojo_window_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

Widget _host(Widget child) => MaterialApp(home: Material(child: child));

void main() {
  testWidgets(
    'right-top notices combine ending actions, prioritize resume, and yield to settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      configureTestServices();
      final controller = PlaybackController();
      controller.setControlsVisible(true);
      Future<void> finishTransitions() async {
        await tester.pump();
        // Finish route/control animations; the video fixture has a loading spinner.
        await tester.pump(const Duration(milliseconds: 300));
      }

      var nextEpisodes = 0;
      controller.timeline.value = controller.timeline.value.copyWith(
        duration: const Duration(minutes: 24),
        position: const Duration(minutes: 23),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => BakaPlayer(
                controller: controller,
                hasNextEpisode: true,
                onNextEpisode: () => nextEpisodes++,
                headerControl: SizedBox(
                  key: const ValueKey('header-capsule-content'),
                  height: 72,
                  child: TextButton(
                    onPressed: () => showPlayerSettingsPanel(
                      context,
                      PlayerSettingsPage(controller: controller),
                    ),
                    child: const Text('打开设置'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        find.text('下一集'),
        findsNothing,
        reason: 'Remaining time alone must never show a next-episode notice',
      );
      controller.overlay.value = controller.overlay.value.copyWith(
        skipState: SkipState.waiting,
        skipLabel: '片尾',
      );
      await tester.pump();
      expect(find.text('跳过'), findsOneWidget);
      expect(find.text('下一集'), findsOneWidget);
      final endingRect = tester.getRect(
        find.byKey(const ValueKey('skip-notice')),
      );
      final capsule = tester.getRect(
        find.byKey(const ValueKey('header-capsule-content')),
      );
      expect(endingRect.top, greaterThanOrEqualTo(capsule.bottom + 8));
      expect(endingRect.overlaps(capsule), isFalse);
      expect(endingRect.width, lessThanOrEqualTo(340));
      controller.setControlsVisible(false);
      await finishTransitions();
      expect(
        tester.getRect(find.byKey(const ValueKey('skip-notice'))),
        endingRect,
      );
      controller.setControlsVisible(true);
      await finishTransitions();
      await tester.tap(find.text('下一集'));
      await tester.pump();
      expect(nextEpisodes, 1);
      controller.setSkipContext(
        const SkipContext(
          sourceKey: 'ep2',
          seriesKey: 'test-series',
          episodeNumber: 2,
        ),
      );
      controller.showJumpToPositionPrompt(
        const Duration(minutes: 12, seconds: 48),
      );
      await tester.pump();
      expect(find.text('继续播放'), findsOneWidget);
      expect(find.text('开启'), findsNothing);
      final resumeRect = tester.getRect(
        find.byKey(const ValueKey('resume-notice')),
      );
      expect(resumeRect.topRight, endingRect.topRight);
      final seeked = controller.seekEvents.first;
      await tester.tap(find.text('继续播放'));
      expect(await seeked, const Duration(minutes: 12, seconds: 48));
      await tester.pump();
      expect(find.text('开启'), findsOneWidget);
      await tester.tap(find.text('打开设置'));
      await finishTransitions();
      expect(find.byKey(const ValueKey('skip-suggestion')), findsNothing);
      await tester.tap(find.byTooltip('关闭设置'));
      await finishTransitions();
      expect(find.text('开启'), findsOneWidget);
      final suggestionRect = tester.getRect(
        find.byKey(const ValueKey('skip-suggestion')),
      );
      expect(suggestionRect.height, lessThanOrEqualTo(44));
      expect(suggestionRect.width, lessThanOrEqualTo(310));
      await tester.tap(find.text('暂不'));
      await tester.pump();
      expect(find.text('开启'), findsNothing);
      expect(controller.preferences.value.enableSkipOpEd, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );

  testWidgets(
    'ending notice combines undo and next with a playback-driven countdown',
    (tester) async {
      tester.view.physicalSize = const Size(360, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      final controller = PlaybackController();
      controller.timeline.value = controller.timeline.value.copyWith(
        duration: const Duration(minutes: 24),
        position: const Duration(minutes: 22),
      );
      const ending = SkipSegment(
        id: 'ed',
        type: 'ed',
        startMs: 1320000,
        endMs: 1410000,
        durationMs: 1440000,
        origin: 'local',
        automatic: true,
      );
      controller.skipData.value = const SkipData(segments: [ending]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                PlayerPrompts(
                  controller: controller,
                  isFullScreen: false,
                  hasNextEpisode: true,
                  onNextEpisode: () {},
                ),
              ],
            ),
          ),
        ),
      );
      controller.previewSkipSegment(ending);
      await tester.pump();
      expect(find.text('撤销'), findsOneWidget);
      expect(find.text('下一集'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        0.25,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.text('30'),
        findsOneWidget,
        reason: 'A paused timeline must not count wall-clock time',
      );
      controller.timeline.value = controller.timeline.value.copyWith(
        position: const Duration(minutes: 23, seconds: 40),
      );
      await tester.pump();
      expect(find.text('20'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pump();
      expect(controller.timeline.value.position, const Duration(minutes: 22));
      controller.previewSkipSegment(ending);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5)); // The actual undo window.
      expect(find.text('撤销'), findsNothing);
      expect(find.text('下一集'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await controller.seek(const Duration(minutes: 10));
      await tester.pump();
      expect(find.text('下一集'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );
  testWidgets('phone settings fit a narrow side panel in both orientations', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
    final controller = PlaybackController();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(844, 390), const Size(390, 844)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPlayerSettingsPanel(
                  context,
                  PlayerSettingsPage(controller: controller),
                ),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byType(PanelContainer));
      expect(panel.right, size.width);
      expect(panel.width, lessThanOrEqualTo(340));
      if (size.width > size.height) {
        expect(panel.width, lessThan(size.width / 2));
      }
      await tester.ensureVisible(find.text('查看与校正区间'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('查看与校正区间')).right, lessThan(panel.right));
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      expect(find.byType(PanelContainer), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });
  testWidgets(
    'skip annotations navigate without overlap, save and clear on episode switch',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      configureTestServices();
      final controller = PlaybackController();
      controller.timeline.value = controller.timeline.value.copyWith(
        duration: const Duration(minutes: 24),
      );
      controller.setSkipContext(const SkipContext(sourceKey: 'first'));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPlayerSettingsPanel(
                  context,
                  PlayerSettingsPage(controller: controller),
                ),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看与校正区间'));
      await tester.pumpAndSettle();
      final settingsScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(PlayerSettingsPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final offset = settingsScroll.position.pixels;
      await tester.tap(find.text('查看与校正区间'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(PlayerSettingsPage), findsNothing);
      expect(find.byType(SkipSegmentsPanel), findsOneWidget);
      expect(find.byTooltip('返回上一级'), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '12.456');
      await tester.enterText(fields.at(1), '102.456');
      await tester.ensureVisible(find.text('保存本机'));
      await tester.tap(find.text('保存本机'));
      await tester.pumpAndSettle();
      expect(controller.skipData.value.segments.single.startMs, 12456);
      expect(controller.skipData.value.segments.single.endMs, 102456);
      expect(tester.takeException(), isNull);
      controller.setSkipContext(const SkipContext(sourceKey: 'second'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(fields.at(0)).controller!.text, isEmpty);
      expect(controller.skipData.value.segments, isEmpty);
      await tester.tap(find.byTooltip('返回上一级'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSettingsPage), findsOneWidget);
      expect(settingsScroll.position.pixels, offset);
      await tester.tap(find.text('查看与校正区间'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSettingsPage), findsOneWidget);
      await tester.tap(find.text('查看与校正区间'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      expect(find.byType(PanelContainer), findsNothing);
      expect(find.text('打开设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );

  testWidgets(
    'subtitle font picker replaces settings and returns with the saved font',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      configureTestServices();
      final controller = PlaybackController();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => SubtitleSettingsPage.show(context, controller),
                child: const Text('打开字幕设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开字幕设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('字体'));
      await tester.tap(find.text('字体'));
      await tester.pumpAndSettle();
      expect(find.byType(SubtitleSettingsPage), findsNothing);
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.text('Microsoft YaHei'));
      await tester.pumpAndSettle();
      expect(find.byType(SubtitleSettingsPage), findsOneWidget);
      expect(find.text('Microsoft YaHei'), findsOneWidget);
      expect(
        PlaybackSettingsService.loadAll().subtitleConfig.fontFamily,
        'Microsoft YaHei',
      );
      await tester.tap(find.text('字体'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SubtitleSettingsPage), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PanelContainer), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );

  testWidgets(
    'wide episode grid stays lazy and reversed selection uses original index',
    (tester) async {
      final episodes = List.generate(
        1000,
        (i) => PlaybackEpisode(title: '第${i + 1}集', lines: const ['url']),
      );
      var selected = -1;
      Widget grid(bool ascending) => _host(
        Builder(
          builder: (context) => CustomScrollView(
            slivers: [
              buildWindowsEpisodeList(
                context: context,
                videoList: episodes,
                ascending: ascending,
                currPlayIndex: 0,
                onEpisodeChanged: (i) => selected = i,
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(grid(true));
      expect(find.byType(EpisodeItem).evaluate().length, lessThan(40));
      expect(
        tester.widget<EpisodeItem>(find.byType(EpisodeItem).first).index,
        0,
      );
      await tester.pumpWidget(grid(false));
      await tester.tap(find.byType(EpisodeItem).first);
      expect(selected, 999);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(find.byType(EpisodeItem).evaluate().length, lessThan(45));
    },
  );

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
      controller.skipData.value = const SkipData(
        segments: [
          SkipSegment(
            id: 'op',
            type: 'op',
            startMs: 0,
            endMs: 90000,
            durationMs: 1440000,
            origin: 'local',
          ),
          SkipSegment(
            id: 'ed',
            type: 'ed',
            startMs: 1320000,
            endMs: 1410000,
            durationMs: 1440000,
            origin: 'local',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BakaPlayer(controller: controller, full: true)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final progressBarFinder = find.byType(ProgressBar);
      expect(progressBarFinder, findsOneWidget);
      expect(find.byType(SkipSegmentTrack), findsOneWidget);
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
          return http.Response('{"code":200,"data":[]}', 200);
        }),
        version: 'test',
        credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
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
}
