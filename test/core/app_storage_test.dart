import 'dart:io';
import 'package:baka/core/app_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _LegacyValue {
  const _LegacyValue(this.value);

  final String value;
}

class _LegacyValueAdapter extends TypeAdapter<_LegacyValue> {
  @override
  int get typeId => 37;

  @override
  _LegacyValue read(BinaryReader reader) => _LegacyValue(reader.readString());

  @override
  void write(BinaryWriter writer, _LegacyValue object) {
    writer.writeString(object.value);
  }
}

// Use the locked path_provider dependency's platform seam for filesystem tests.

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  int scans = 0;
  @override
  Future<String?> getTemporaryPath() async {
    scans++;
    return path;
  }

  @override
  Future<String?> getApplicationCachePath() async => '$path/own';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('recovery', () {
    test(
      'backs up and rebuilds only a box with an unknown legacy type',
      () async {
        final hiveDirectory = await Directory.systemTemp.createTemp(
          'baka-storage-recovery-test-',
        );
        addTearDown(() async {
          await Hive.close();
          if (await hiveDirectory.exists()) {
            await hiveDirectory.delete(recursive: true);
          }
        });
        Hive.init(hiveDirectory.path);
        Hive.registerAdapter<_LegacyValue>(_LegacyValueAdapter());

        final brokenBox = await Hive.openBox<Map>(
          AppStorage.videoProgressBoxName,
        );
        await brokenBox.put('progress', <String, Object>{
          'legacy': const _LegacyValue('unreadable'),
        });
        await Hive.close();
        Hive.resetAdapters();

        final recoveries = await AppStorage.init(hiveDirectory: hiveDirectory);

        expect(recoveries, hasLength(1));
        expect(recoveries.single.boxName, AppStorage.videoProgressBoxName);
        expect(recoveries.single.reason, contains('unknown typeId: 69'));
        expect(recoveries.single.backupPath, isNotNull);
        expect(await File(recoveries.single.backupPath!).exists(), isTrue);
        expect(AppStorage.videoProgressBox.isEmpty, isTrue);
        expect(AppStorage.customSourcesBox.isOpen, isTrue);
      },
    );
  });

  group('lazy boxes', () {
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
  });

  group('cache scan', () {
    test(
      'concurrent size queries share one scan and later queries rescan',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'baka-cache-test-',
        );
        final original = PathProviderPlatform.instance;
        final paths = _Paths(directory.path);
        PathProviderPlatform.instance = paths;
        try {
          final own = await Directory('${directory.path}/own').create();
          await File('${own.path}/data').writeAsBytes(List.filled(1024, 0));
          final first = AppStorage.getCacheSize();
          final batch = List.generate(2, (_) => AppStorage.getCacheSize());
          for (final future in batch) {
            expect(identical(future, first), isTrue);
          }
          expect(await first, 1024);
          await Future.wait(batch);
          expect(paths.scans, 1);
          await File('${own.path}/data').writeAsBytes(List.filled(2048, 0));
          expect(await AppStorage.getCacheSize(), 2048);
          expect(paths.scans, 2);
        } finally {
          PathProviderPlatform.instance = original;
          await directory.delete(recursive: true);
        }
      },
    );
  });
}
