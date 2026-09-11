import 'package:baka/app/watch_party_links.dart';
import 'dart:io';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:baka/instance.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

Future<void> configurePlatform() async {
  if (Platform.isWindows) WatchPartyLinks.registerWindowsScheme();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );

  if (Platform.isAndroid) {
    const platformChannel = MethodChannel('baka/platform');
    Map<String, dynamic>? displayDiagnostics;
    try {
      Instances.isTV =
          await platformChannel.invokeMethod<bool>('isTV') ?? false;
    } catch (error, stackTrace) {
      Instances.isTV = false;
      AppLogger.instance.warning(
        'Android TV detection failed; using phone behavior',
        tag: 'Display',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      displayDiagnostics = await platformChannel
          .invokeMapMethod<String, dynamic>('getDisplayDiagnostics');
      AppLogger.instance.info(
        'Android display diagnostics: $displayDiagnostics',
        tag: 'Display',
      );
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'Unable to read Android display diagnostics',
        tag: 'Display',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (Instances.isTV) {
      AppLogger.instance.info(
        'TV rendering policy: system display mode, '
        'impeller=${displayDiagnostics?['impellerEnabled']}',
        tag: 'Display',
      );
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      // Let Android TV keep the display mode selected by the system. Forcing
      // the highest phone refresh mode can make Flutter and video textures
      // alternate frames on TV firmware with incomplete mode support.
      try {
        await FlutterDisplayMode.setHighRefreshRate();
        AppLogger.instance.info(
          'Android rendering policy: high refresh mode request completed',
          tag: 'Display',
        );
      } catch (error, stackTrace) {
        AppLogger.instance.warning(
          'Android high refresh mode request failed',
          tag: 'Display',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  if (Instances.isDesktopPlatform) {
    doWhenWindowReady(() {
      appWindow.minSize = const Size(800, 600);
      appWindow.size = const Size(1280, 720);
      appWindow.alignment = Alignment.center;
      appWindow.title = 'Baka';
      appWindow.show();
    });
  }
}
