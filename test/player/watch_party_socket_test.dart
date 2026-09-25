import '../support/app_dependencies.dart';
import 'package:baka/instance.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:baka/core/account_session.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:baka/models/watch_party.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';

const _invite = WatchPartyInvite(
  roomId: 'room-1',
  inviteCode: 'invite-1',
  inviteUrl: 'https://www.anibaka.com/watch/invite-1',
  syncplayHost: 'sync.anibaka.com',
  syncplayPort: 8999,
  syncplayRoom: '1234567890',
  title: 'Show',
  episodeIndex: 0,
);

class _PermissionPlayer extends PlaybackController {
  final permissions = <bool>[];
  @override
  Future<void> configureWatchParty({
    required bool connected,
    required bool canControl,
  }) async {
    permissions.add(canControl);
    await super.configureWatchParty(
      connected: connected,
      canControl: canControl,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final testHttpOverrides = HttpOverrides.current;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
  });
  tearDownAll(() => HttpOverrides.global = testHttpOverrides);

  test(
    'permissions update only on change and restore after reconnect',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final ready = [Completer<void>(), Completer<void>()];
      final sockets = <WebSocket>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        final index = sockets.length;
        sockets.add(socket);
        socket.listen((raw) {
          final message = jsonDecode(raw as String);
          if (message['type'] == 'ping') {
            socket.add(jsonEncode(_snapshotEnvelope));
          }
          if (message['type'] == 'ready.set') ready[index].complete();
        });
      });
      final service = WatchPartyService(
        session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
        getInviteRequest: (_) async => _invite,
        joinRoomRequest: (_, _) async =>
            'ws://${server.address.address}:${server.port}/room',
      );
      final player = _PermissionPlayer();
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
      await service.joinInvite('invite-1');
      await ready[0].future.timeout(const Duration(seconds: 5));
      expect(player.permissions, [true]);
      for (final (revision, canControl) in [(2, true), (3, false), (4, true)]) {
        final message =
            jsonDecode(jsonEncode(_snapshotEnvelope)) as Map<String, dynamic>;
        message['payload']['revision'] = revision;
        message['payload']['members'][0]['controller'] = canControl;
        final received = Completer<void>();
        void onState() {
          if (service.state.value.snapshot?.revision == revision &&
              !received.isCompleted) {
            received.complete();
          }
        }

        service.state.addListener(onState);
        sockets[0].add(jsonEncode(message));
        await received.future.timeout(const Duration(seconds: 5));
        service.state.removeListener(onState);
        await Future<void>.delayed(Duration.zero);
      }
      expect(player.permissions, [true, false, true]);
      await sockets[0].close();
      await ready[1].future.timeout(const Duration(seconds: 5));
      expect(service.state.value.connected, isTrue);
      expect(player.permissions, [true, false, true, false, true]);
    },
  );

  test('connection actively requests the initial room snapshot', () async {
    var pingRequests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        if (message['type'] != 'ping') return;
        pingRequests++;
        socket.add(jsonEncode(_snapshotEnvelope));
      });
    });

    final service = WatchPartyService(
      session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
      getInviteRequest: (_) async => _invite,
      joinRoomRequest: (_, _) async =>
          'ws://${server.address.address}:${server.port}/room',
    );
    addTearDown(service.leave);

    await service.joinInvite('invite-1', nickname: 'Tester');

    expect(pingRequests, 1);
    expect(service.state.value.connected, isTrue);
    expect(service.state.value.snapshot?.roomId, 'room-1');
  });

  test(
    'invalid initial snapshot fails immediately with a specific error',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((raw) {
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          if (message['type'] == 'ping') {
            socket.add(
              jsonEncode({
                'v': 1,
                'type': 'room.snapshot',
                'revision': 1,
                'payload': {'roomId': 'incomplete'},
              }),
            );
          }
        });
      });

      final service = WatchPartyService(
        session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
        getInviteRequest: (_) async => _invite,
        joinRoomRequest: (_, _) async =>
            'ws://${server.address.address}:${server.port}/room',
      );
      addTearDown(service.leave);
      final elapsed = Stopwatch()..start();

      await expectLater(
        service.joinInvite('invite-1', nickname: 'Tester'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '无法解析一起看房间状态',
          ),
        ),
      );

      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
      expect(service.state.value.status, WatchPartyConnectionStatus.failed);
    },
  );
}

const _snapshotEnvelope = <String, dynamic>{
  'v': 1,
  'type': 'room.snapshot',
  'revision': 1,
  'payload': <String, dynamic>{
    'roomId': 'room-1',
    'inviteCode': 'invite-1',
    'syncplayRoom': '1234567890',
    'ownerId': 'member-1',
    'selfId': 'member-1',
    'revision': 1,
    'serverTime': 1700000000000,
    'playback': <String, dynamic>{'position': 0, 'paused': true},
    'media': <String, dynamic>{
      'bgmSubjectId': 1,
      'episodeIndex': 0,
      'title': 'Show',
      'duration': 1440,
    },
    'members': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'member-1',
        'name': 'Tester',
        'protocol': 'anibaka',
        'verified': true,
        'controller': true,
        'ready': false,
      },
    ],
    'chat': null,
  },
};
