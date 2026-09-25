import 'package:baka/instance.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  test('去广告开关在持久化后通知当前媒体重新处理，其他设置不触发', () async {
    final controller = PlaybackController();
    final changes = <bool>[];
    controller.onHlsAdFilterChanged = (enabled) async {
      expect(Instances.sp.getBool('player_filterHlsAds'), enabled);
      changes.add(enabled);
    };
    await controller.updatePreferences(
      controller.preferences.value.copyWith(filterHlsAds: true),
    );
    await controller.updatePreferences(
      controller.preferences.value.copyWith(showSystemTime: true),
    );
    await controller.updatePreferences(controller.preferences.value);
    await controller.updatePreferences(
      controller.preferences.value.copyWith(filterHlsAds: false),
    );
    expect(changes, [true, false]);
    await controller.dispose();
  });
}
