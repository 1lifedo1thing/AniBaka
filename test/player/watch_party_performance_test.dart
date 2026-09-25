import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

// The service and socket are real. Only native player I/O is replaced by a
// deterministic gate so every run receives the same burst while seek is busy.
class _Player extends PlaybackController {
  final entered = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
  int seeks = 0;
  int configurations = 0;
  @override
  Future<void> configureWatchParty({
    required bool connected,
    required bool canControl,
  }) async {
    configurations++;
    await super.configureWatchParty(
      connected: connected,
      canControl: canControl,
    );
  }

  @override
  Future<void> seek(
    Duration position, {
    bool remote = false,
    bool fromSlider = false,
  }) async {
    seeks++;
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.seek(position, remote: remote);
    if (position.inSeconds == 2010 && !finished.isCompleted) {
      finished.complete();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fixed socket burst reaches the latest paused position', () async {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final connected = Completer<WebSocket>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      connected.complete(socket);
      socket.listen((raw) {
        if (jsonDecode(raw as String)['type'] == 'ping') {
          socket.add(_snapshot(1));
        }
      });
    });
    final service = WatchPartyService(
      session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
      getInviteRequest: (_) async => const WatchPartyInvite(
        roomId: 'room',
        inviteCode: 'code',
        inviteUrl: '',
        syncplayHost: '',
        syncplayPort: 0,
        syncplayRoom: 'room',
        title: 'Show',
        episodeIndex: 0,
      ),
      joinRoomRequest: (_, _) async =>
          'ws://${server.address.address}:${server.port}',
    );
    final player = _Player();
    player.timeline.value = player.timeline.value.copyWith(
      duration: const Duration(hours: 2),
    );
    final content = PlaybackContent(
      sources: sourceRepository,
      collections: collections,
      history: historyRepository,
      request: PlaybackRequest.fromMap({
        'source': '_local',
        'localFilePath': 'test.mp4',
      }),
    );
    service.attachPlayer(player, content, onEpisodeRequested: (_) async {});
    addTearDown(() async {
      await service.close();
      await player.dispose();
      await content.dispose();
    });
    await service.joinInvite('code');
    await player.entered.future;
    final received = Completer<void>();
    service.state.addListener(() {
      if (service.state.value.snapshot?.revision == 201 &&
          !received.isCompleted) {
        received.complete();
      }
    });
    final socket = await connected.future;
    for (var i = 2; i <= 201; i++) {
      socket.add(_snapshot(i));
    }
    await received.future.timeout(const Duration(seconds: 10));
    final stopwatch = Stopwatch()..start();
    player.release.complete();
    await player.finished.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(Duration.zero);
    stopwatch.stop();
    expect(player.timeline.value.position.inSeconds, 2010);
    print(
      'WATCH_PARTY_BENCH snapshots=201 seeks=${player.seeks} configurations=${player.configurations} drain_us=${stopwatch.elapsedMicroseconds}',
    );
    if (const bool.fromEnvironment('CHECK_REFACTOR')) {
      expect(player.seeks, 2);
      expect(player.configurations, 1);
    }
  });
}

String _snapshot(int revision) => jsonEncode({
  'type': 'room.snapshot',
  'payload': {
    'roomId': 'room',
    'inviteCode': 'code',
    'syncplayRoom': 'room',
    'ownerId': 'owner',
    'selfId': 'viewer',
    'revision': revision,
    'serverTime': 0,
    'playback': {'position': revision * 10, 'paused': true, 'doSeek': false},
    'media': {'episodeIndex': 0, 'title': 'Show', 'duration': 7200},
    'members': [],
    'chat': [],
  },
});
