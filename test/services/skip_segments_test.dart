import 'dart:async';
import 'dart:convert';

import 'package:baka/core/api_transport.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/skip_segment.dart';
import 'package:baka/services/playback/playback_settings.dart';
import 'package:baka/services/playback/skip_segments.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/app_dependencies.dart';

const segment = SkipSegment(
  id: 'a',
  type: 'op',
  startMs: 10000,
  endMs: 100000,
  durationMs: 1440000,
  origin: 'aniskip',
  automatic: true,
);
final context = SkipContext(
  sourceKey: SkipContext.sourceIdentity(['rule', 'episode', 'line']),
  subjectId: 1,
  episodeId: 10,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
  });

  test('natural entry skips once, late data and manual re-entry do not', () {
    final session = SkipSession()..install([segment], 9000);
    expect(
      session.observe(10050, duration: 1440000, canAuto: true)?.automatic,
      isTrue,
    );
    session.seek(12000);
    expect(
      session.observe(12250, duration: 1440000, canAuto: true)?.automatic,
      isFalse,
    );
    session.reset();
    session.install([segment], 50000);
    expect(
      session.observe(50250, duration: 1440000, canAuto: true)?.automatic,
      isFalse,
    );
    session.reset();
    session.install([segment], 9000);
    expect(
      session.observe(10100, duration: 1440000, canAuto: false)?.automatic,
      isFalse,
    );
    session.dismiss(segment);
    expect(session.observe(10200, duration: 1440000, canAuto: true), isNull);
  });

  test(
    'episode one preserves both segments even when automatic skip is enabled',
    () async {
      const ending = SkipSegment(
        id: 'ed',
        type: 'ed',
        startMs: 1300000,
        endMs: 1390000,
        durationMs: 1440000,
        origin: 'local',
        automatic: true,
      );
      final session = SkipSession()..install([segment, ending], 0);
      for (final time in [10000, 1300000]) {
        expect(
          session.observe(
            time,
            duration: 1440000,
            canAuto: true,
            episodeNumber: 1,
          ),
          isNull,
        );
      }
      final ctrl = PlaybackController();
      ctrl.preferences.value = ctrl.preferences.value.copyWith(
        enableSkipOpEd: true,
      );
      ctrl.setSkipContext(
        const SkipContext(sourceKey: 'episode-one', episodeNumber: 1),
      );
      ctrl.timeline.value = ctrl.timeline.value.copyWith(
        duration: const Duration(minutes: 24),
      );
      for (final value in [segment, ending]) {
        ctrl.previewSkipSegment(value);
        expect(ctrl.timeline.value.position, Duration.zero);
      }
      expect(ctrl.overlay.value.showSkipSuggestion, isFalse);
      session.reset();
      session.install([segment], 0);
      expect(
        session
            .observe(10000, duration: 1440000, canAuto: true, episodeNumber: 2)
            ?.automatic,
        isTrue,
      );
      await ctrl.dispose();
    },
  );

  test(
    'episode-two opt-in persists per series and respects room control',
    () async {
      const second = SkipContext(
        sourceKey: 'ep2',
        seriesKey: 'series-a',
        episodeNumber: 2,
      );
      var ctrl = PlaybackController();
      ctrl.setSkipContext(second);
      expect(ctrl.overlay.value.showSkipSuggestion, isTrue);
      await ctrl.answerSkipSuggestion(false);
      expect(ctrl.preferences.value.enableSkipOpEd, isFalse);
      await ctrl.dispose();
      ctrl = PlaybackController();
      ctrl.setSkipContext(second.bind(1, 2));
      expect(ctrl.overlay.value.showSkipSuggestion, isFalse);
      const other = SkipContext(
        sourceKey: 'other-ep2',
        seriesKey: 'series-b',
        episodeNumber: 2,
      );
      await ctrl.configureWatchParty(connected: true, canControl: false);
      ctrl.setSkipContext(other);
      expect(ctrl.overlay.value.showSkipSuggestion, isFalse);
      await ctrl.configureWatchParty(connected: false, canControl: true);
      expect(ctrl.overlay.value.showSkipSuggestion, isTrue);
      await ctrl.answerSkipSuggestion(true);
      expect(PlaybackSettingsService.loadAll().enableSkipOpEd, isTrue);
      expect(ctrl.overlay.value.showSkipSuggestion, isFalse);
      ctrl.setSkipContext(
        const SkipContext(
          sourceKey: 'first',
          seriesKey: 'series-c',
          episodeNumber: 1,
        ),
      );
      expect(ctrl.overlay.value.showSkipSuggestion, isFalse);
      await ctrl.dispose();
    },
  );

  test('duration boundary, ending tail, and episode reset are independent', () {
    expect(segment.fits(1442000), isTrue);
    expect(segment.fits(1442001), isFalse);
    const ending = SkipSegment(
      id: 'ed',
      type: 'ed',
      startMs: 1300000,
      endMs: 1390000,
      durationMs: 1440000,
      origin: 'community',
      automatic: true,
    );
    final session = SkipSession()..install([segment, ending], 0);
    expect(
      session.observe(10000, duration: 1440000, canAuto: true)?.automatic,
      isTrue,
    );
    session.observe(1299900, duration: 1440000, canAuto: true);
    expect(
      session.observe(1300100, duration: 1440000, canAuto: true)?.segment.endMs,
      1390000,
    );
    expect(session.observe(1400000, duration: 1440000, canAuto: true), isNull);
    session.reset();
    session.install([segment], 0);
    expect(
      session.observe(10000, duration: 1440000, canAuto: true)?.automatic,
      isTrue,
    );
  });

  test(
    'explicit episode matching does not use catalog order or special labels',
    () {
      final episodes = [
        {'id': 12, 'type': 0, 'sort': 2},
        {'id': 11, 'type': 0, 'sort': 1},
        {'id': 13, 'type': 1, 'sort': 1},
      ];
      expect(matchSkipEpisode('第02集', episodes), 12);
      expect(matchSkipEpisode('EP1', episodes), 11);
      for (final title in [
        'SP1',
        '合集',
        '第一季',
        'S02E01',
        '12-13',
        'EP1-2',
        '第01集-第02集',
      ]) {
        expect(matchSkipEpisode(title, episodes), isNull);
      }
      episodes.add({'id': 14, 'type': 0, 'sort': 1});
      expect(matchSkipEpisode('01', episodes), isNull);
    },
  );

  test(
    'personal corrections and opt-out stay with their source and timeline',
    () async {
      final service = SkipSegmentsService();
      const personal = SkipSegment(
        id: 'local',
        type: 'op',
        startMs: 5000,
        endMs: 95000,
        durationMs: 1440000,
        origin: 'local',
        automatic: true,
      );
      await service.saveLocal(context, personal);
      expect(
        service.mergeLocal(context, 1440000, [segment]).single.startMs,
        5000,
      );
      final other = SkipContext(
        sourceKey: context.sourceKey,
        timelineKey: 'hls:other',
      );
      expect(
        service.mergeLocal(other, 1440000, [segment]).single.startMs,
        10000,
      );
      await service.disable(context, 'op', true);
      expect(service.mergeLocal(context, 1440000, [segment]), isEmpty);
      await service.disable(context, 'op', false);
      expect(
        service.mergeLocal(context, 1440000, [segment]).single.origin,
        'local',
      );
    },
  );

  test(
    'old server retains local annotations and PUT validates envelope',
    () async {
      final service = SkipSegmentsService();
      await service.saveLocal(context, segment);
      final previous = apiTransport;
      apiTransport = ApiTransport(
        session: previous.session,
        version: 'test',
        credentialOrigin: previous.credentialOrigin,
        client: MockClient((request) async {
          if (request.method == 'PUT') {
            return http.Response('{"code":403,"message":"forbidden"}', 200);
          }
          return http.Response('<html>old server</html>', 200);
        }),
      );
      addTearDown(() {
        apiTransport.close();
        apiTransport = previous;
      });
      final data = await service.load(context, 1440000);
      expect(data.segments.single.id, 'a');
      expect(data.message, contains('暂不支持'));
      await expectLater(
        service.feedback(context, segment, true),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test('switching episode discards an in-flight timestamp response', () async {
    final arrived = Completer<void>(), release = Completer<void>();
    final previous = apiTransport;
    apiTransport = ApiTransport(
      session: previous.session,
      version: 'test',
      credentialOrigin: previous.credentialOrigin,
      client: MockClient((request) async {
        if (!arrived.isCompleted) arrived.complete();
        await release.future;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'segments': [segment.toJson()],
            },
          }),
          200,
        );
      }),
    );
    addTearDown(() {
      apiTransport.close();
      apiTransport = previous;
    });
    final ctrl = PlaybackController();
    ctrl.timeline.value = ctrl.timeline.value.copyWith(
      duration: const Duration(minutes: 24),
    );
    ctrl.setSkipContext(context);
    final pending = ctrl.refreshSkipSegments(force: true);
    await arrived.future;
    ctrl.setSkipContext(null);
    release.complete();
    await pending;
    expect(ctrl.skipData.value.segments, isEmpty);
    expect(ctrl.skipContext, isNull);
    await ctrl.dispose();
  });
}
