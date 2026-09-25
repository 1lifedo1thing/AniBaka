import 'dart:async';

import 'package:baka/core/account_session.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_dependencies.dart';

class _Player extends PlaybackController {
  int seeks = 0;
  bool failSeek = false;
  Completer<void>? seekGate;
  final seeking = Completer<void>();

  @override
  Future<void> play({bool remote = false}) async {
    core.value = core.value.copyWith(playing: true);
  }

  @override
  Future<void> pause({bool remote = false}) async {
    core.value = core.value.copyWith(playing: false);
  }

  @override
  Future<void> seek(
    Duration target, {
    bool fromSlider = false,
    bool remote = false,
  }) async {
    seeks++;
    if (!seeking.isCompleted) seeking.complete();
    await seekGate?.future;
    if (failSeek) throw StateError('test seek failed');
    await super.seek(target, remote: remote, fromSlider: fromSlider);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WatchPartyService service;
  late PlaybackContent content;
  late _Player player;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
    service = WatchPartyService(
      session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
    );
    content = PlaybackContent(
      sources: sourceRepository,
      collections: collections,
      history: historyRepository,
      request: PlaybackRequest.fromMap({
        'source': '_local',
        'localFilePath': 'test.mp4',
      }),
    );
    player = _Player();
    player.timeline.value = player.timeline.value.copyWith(
      duration: const Duration(hours: 1),
    );
    addTearDown(() async {
      await service.close();
      await player.dispose();
      await content.dispose();
    });
  });

  void attach({double position = 10, bool paused = true, bool doSeek = false}) {
    service.state.value = WatchPartyViewState(
      status: WatchPartyConnectionStatus.connected,
      snapshot: WatchPartySnapshot.fromJson({
        'roomId': 'room',
        'inviteCode': 'code',
        'syncplayRoom': 'room',
        'revision': 1,
        'serverTime': 0,
        'playback': {'position': position, 'paused': paused, 'doSeek': doSeek},
        'media': {'title': 'Show', 'episodeIndex': 0, 'duration': 3600},
      }),
    );
    service.attachPlayer(player, content, onEpisodeRequested: (_) async {});
  }

  for (final seconds in [0.25, 0.3, 10.0]) {
    test('paused drift $seconds seeks at most once', () async {
      attach(position: seconds);
      await Future<void>.delayed(Duration.zero);
      expect(player.seeks, seconds > 0.25 ? 1 : 0);
      expect(player.core.value.playing, isFalse);
    });
  }
  test('explicit seek applies even below the drift threshold', () async {
    attach(position: 0.1, doSeek: true);
    await Future<void>.delayed(Duration.zero);
    expect(player.seeks, 1);
    expect(player.timeline.value.position.inMilliseconds, 100);
  });
  test(
    'hard seek resumes at normal speed instead of correcting stale drift',
    () async {
      attach(paused: false);
      await Future<void>.delayed(Duration.zero);
      expect(player.seeks, 1);
      expect(player.core.value.playing, isTrue);
      expect(player.core.value.playbackRate, 1.0);
    },
  );
  for (final localPosition in [0, 4]) {
    test(
      'small playing drift from $localPosition adjusts rate without seeking',
      () async {
        player.timeline.value = player.timeline.value.copyWith(
          position: Duration(seconds: localPosition),
        );
        attach(position: 2, paused: false);
        await Future<void>.delayed(Duration.zero);
        expect(player.seeks, 0);
        expect(
          player.core.value.playbackRate,
          localPosition == 0 ? 1.05 : 0.95,
        );
      },
    );
  }
  for (final leave in [false, true]) {
    test(
      '${leave ? 'leave' : 'detach'} during seek cancels remaining playback changes',
      () async {
        player.seekGate = Completer<void>();
        attach(paused: false);
        await player.seeking.future;
        if (leave) {
          await service.leave();
        } else {
          service.detachPlayer(player);
        }
        player.seekGate!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(player.core.value.playing, isFalse);
        expect(player.core.value.playbackRate, 1.0);
      },
    );
  }
  test(
    'failed seek does not discard a pending replacement player snapshot',
    () async {
      final oldPlayer = player;
      oldPlayer.seekGate = Completer<void>();
      oldPlayer.failSeek = true;
      attach(paused: false);
      await oldPlayer.seeking.future;
      player = _Player();
      player.timeline.value = player.timeline.value.copyWith(
        duration: const Duration(hours: 1),
      );
      attach(position: 20);
      oldPlayer.seekGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(player.timeline.value.position.inSeconds, 20);
      expect(player.seeks, 1);
      expect(oldPlayer.core.value.playing, isFalse);
      await oldPlayer.dispose();
    },
  );
}
