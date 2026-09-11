import '../support/app_dependencies.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/media_session.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();
  });

  test(
    'media handler forwards commands and mirrors controller metadata',
    () async {
      final controller = PlaybackController();
      final handler = PlaybackAudioHandler();
      final service = MediaSessionService(audioHandler: handler);
      var nextCalls = 0;
      var previousCalls = 0;

      controller.setMediaInfo(
        const PlaybackMediaInfo(
          title: '作品',
          episode: '第 2 集',
          imageUrl: 'https://example.test/cover.jpg',
          episodeIndex: 1,
          totalEpisodes: 12,
        ),
      );
      service.attach(
        controller,
        onNextEpisode: () => nextCalls++,
        onPreviousEpisode: () => previousCalls++,
      );

      await handler.play();
      await handler.pause();
      await handler.setSpeed(1.5);
      controller.timeline.value = controller.timeline.value.copyWith(
        duration: const Duration(minutes: 24),
      );
      await handler.seek(const Duration(minutes: 3));
      await handler.skipToNext();
      await handler.skipToPrevious();

      expect(controller.core.value.playbackRate, 1.5);
      expect(controller.timeline.value.position, const Duration(minutes: 3));
      expect(nextCalls, 1);
      expect(previousCalls, 1);
      expect(handler.mediaItem.value?.title, '作品 - 第 2 集');
      expect(handler.mediaItem.value?.duration, const Duration(minutes: 24));

      service.detach();
      await controller.dispose();
    },
  );
}
