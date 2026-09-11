import 'package:baka/instance.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_dependencies.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dispose shares completion and releases resources once', () async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configureTestServices();

    final controller = PlaybackController();
    final first = controller.dispose();
    expect(identical(first, controller.dispose()), isTrue);
    await first;
  });
}
