import 'package:baka/services/source/source_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/collection/collection_repository.dart';
import '../support/app_dependencies.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/app/watch_party_links.dart';
import 'dart:async';

import 'package:baka/instance.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
  });

  test('snapshot identifies self, owner, controller, and external members', () {
    final snapshot = WatchPartySnapshot.fromJson({
      'roomId': 'room-1',
      'inviteCode': 'invite-1',
      'syncplayRoom': '+AniBaka-room:ABCDEF123456',
      'ownerId': 'owner',
      'selfId': 'owner',
      'revision': 8,
      'serverTime': 1700000000000,
      'playback': {'position': 42.5, 'paused': false, 'setBy': 'Owner'},
      'media': {
        'bgmSubjectId': 123,
        'episodeIndex': 2,
        'title': 'Show',
        'duration': 1440,
      },
      'members': [
        {
          'id': 'owner',
          'name': 'Owner',
          'protocol': 'anibaka',
          'verified': true,
          'controller': true,
          'ready': true,
        },
        {
          'id': 'external',
          'name': 'mpv-user',
          'protocol': 'syncplay',
          'verified': false,
          'controller': false,
          'ready': false,
        },
      ],
      'chat': const [],
    });

    expect(snapshot.isOwner, isTrue);
    expect(snapshot.canControl, isTrue);
    expect(snapshot.media.bgmSubjectId, 123);
    expect(snapshot.members.last.protocol, 'syncplay');
    expect(snapshot.members.last.verified, isFalse);
  });

  test(
    'snapshot normalizes nullable server collections once at the boundary',
    () {
      final snapshot = WatchPartySnapshot.fromJson({
        'roomId': 'room-1',
        'inviteCode': 'invite-1',
        'syncplayRoom': '1234567890',
        'revision': 1,
        'serverTime': 1700000000000,
        'playback': {'position': 0, 'paused': true},
        'media': {'episodeIndex': 0, 'title': 'Show', 'duration': 1440},
        'members': null,
        'chat': null,
      });

      expect(snapshot.members, isEmpty);
      expect(snapshot.chat, isEmpty);
    },
  );

  test('invite parses active room list metadata', () {
    final invite = WatchPartyInvite.fromJson({
      'roomId': 'room-1',
      'inviteCode': 'invite-1',
      'inviteUrl': 'https://www.anibaka.com/watch/invite-1',
      'syncplayHost': 'sync.anibaka.com',
      'syncplayPort': 8999,
      'syncplayRoom': '1234567890',
      'title': 'Show',
      'episodeIndex': 2,
      'memberCount': 4,
    });

    expect(invite.memberCount, 4);
    expect(invite.syncplayRoom, '1234567890');
  });

  test('watch party QR values accept links, app links, and invite codes', () {
    expect(
      WatchPartyLinks.inviteCodeFromValue(
        'https://www.anibaka.com/watch/Abc_123-xyz?from=qr',
      ),
      'Abc_123-xyz',
    );
    expect(
      WatchPartyLinks.inviteCodeFromValue('anibaka://watch/1234567890'),
      '1234567890',
    );
    expect(WatchPartyLinks.inviteCodeFromValue('1234567890'), '1234567890');
    expect(
      WatchPartyLinks.inviteCodeFromValue('https://example.com/watch/x'),
      isNull,
    );
  });

  test('failed join request leaves connecting state retryable', () async {
    var ticketRequested = false;
    final service = WatchPartyService(
      session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
      getInviteRequest: (_) async => throw StateError('房间不存在'),
      joinRoomRequest: (_, _) async {
        ticketRequested = true;
        return 'ws://unused';
      },
    );

    await expectLater(
      service.joinInvite('missing-room', nickname: 'Tester'),
      throwsA(isA<StateError>()),
    );

    expect(service.state.value.status, WatchPartyConnectionStatus.failed);
    expect(service.state.value.error, '房间不存在');
    expect(ticketRequested, isFalse);
    await service.leave();
  });

  test(
    'leaving invalidates an in-flight join before it requests a ticket',
    () async {
      final inviteCompleter = Completer<WatchPartyInvite>();
      var ticketRequests = 0;
      final service = WatchPartyService(
        session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
        getInviteRequest: (_) => inviteCompleter.future,
        joinRoomRequest: (_, _) async {
          ticketRequests++;
          return 'ws://unused';
        },
      );

      final joining = service.joinInvite('invite-1', nickname: 'Tester');
      await Future<void>.delayed(Duration.zero);
      expect(service.state.value.status, WatchPartyConnectionStatus.connecting);

      await service.leave();
      inviteCompleter.complete(_invite);
      await joining;

      expect(ticketRequests, 0);
      expect(
        service.state.value.status,
        WatchPartyConnectionStatus.disconnected,
      );
    },
  );

  test(
    'viewer controls are blocked while remote room updates still apply',
    () async {
      final controller = PlaybackController();
      controller.timeline.value = controller.timeline.value.copyWith(
        duration: const Duration(minutes: 10),
      );
      await controller.configureWatchParty(connected: true, canControl: false);

      await controller.play();
      await controller.pause();
      await controller.seek(const Duration(seconds: 50));
      await controller.setRate(2);
      expect(controller.core.value.playing, isFalse);
      expect(controller.core.value.playbackRate, 1.0);
      expect(controller.timeline.value.position, Duration.zero);

      await controller.setRate(0.95, roomCorrection: true);
      expect(controller.core.value.playbackRate, 0.95);
      await controller.seek(const Duration(seconds: 50), remote: true);
      expect(controller.timeline.value.position, const Duration(seconds: 50));

      await controller.dispose();
    },
  );

  test('disposing an old player cannot detach its replacement', () async {
    final service = WatchPartyService(
      session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
    );
    final oldController = PlaybackController();
    final newController = PlaybackController();
    final oldContent = PlaybackContent(
      sources: sourceRepository,
      collections: collections,
      history: historyRepository,
      request: PlaybackRequest.fromMap(const <String, Object>{
        'source': '_local',
        'localFilePath': 'old.mp4',
      }),
    );
    final newContent = PlaybackContent(
      sources: sourceRepository,
      collections: collections,
      history: historyRepository,
      request: PlaybackRequest.fromMap(const <String, Object>{
        'source': '_local',
        'localFilePath': 'new.mp4',
      }),
    );

    service.attachPlayer(
      oldController,
      oldContent,
      onEpisodeRequested: (_) async {},
    );
    service.attachPlayer(
      newController,
      newContent,
      onEpisodeRequested: (_) async {},
    );

    service.detachPlayer(oldController);
    expect(service.hasAttachedPlayer, isTrue);

    service.detachPlayer(newController);
    expect(service.hasAttachedPlayer, isFalse);
    oldContent.dispose();
    newContent.dispose();
    await oldController.dispose();
    await newController.dispose();
  });
}
