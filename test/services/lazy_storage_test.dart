import 'dart:io';
import 'package:baka/core/app_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('baka-lazy-');
    Hive.init(directory.path);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  test('startup opens its dependencies and defers feature storage', () async {
    await AppStorage.init(
      hiveDirectory: directory,
      boxes: AppStorage.startupBoxes,
    );
    expect(Hive.isBoxOpen(AppStorage.homeCacheBoxName), isTrue);
    expect(Hive.isBoxOpen(AppStorage.customSourcesBoxName), isFalse);
    expect(Hive.isBoxOpen(AppStorage.downloadTasksBoxName), isFalse);
    expect(Hive.isBoxOpen(AppStorage.threadCommentsBoxName), isFalse);
    final opening = AppStorage.open(AppStorage.downloadTasksBoxName);
    expect(
      identical(opening, AppStorage.open(AppStorage.downloadTasksBoxName)),
      isTrue,
    );
    await opening;
    expect(AppStorage.downloadTasksBox.isOpen, isTrue);
  });
  test('a failed box open does not poison subsequent attempts', () async {
    final conflict = await Hive.openBox<String>(
      AppStorage.threadCommentsBoxName,
    );
    // A box opened by a different owner still has to obey its typed contract.
    expect(() => AppStorage.threadCommentsBox, throwsA(isA<HiveError>()));
    await conflict.close();
    await AppStorage.open(AppStorage.threadCommentsBoxName);
    expect(AppStorage.threadCommentsBox.isOpen, isTrue);
  });
}
