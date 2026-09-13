import 'package:baka/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unchanged settings reuse the resolved themes', () {
    final first = AppTheme.resolve(
      fontFamily: AppFonts.systemFont,
      fontWeight: FontWeight.w400,
    );
    final second = AppTheme.resolve(
      fontFamily: AppFonts.systemFont,
      fontWeight: FontWeight.w400,
    );
    expect(identical(first.light, second.light), isTrue);
    expect(identical(first.dark, second.dark), isTrue);
  });

  test('weight changes retain colors and restore default text hierarchy', () {
    final lightScheme = ColorScheme.fromSeed(seedColor: Colors.green);
    final darkScheme = ColorScheme.fromSeed(
      seedColor: Colors.orange,
      brightness: Brightness.dark,
    );
    final original = AppTheme.resolve(
      fontFamily: AppFonts.systemFont,
      fontWeight: FontWeight.w400,
      lightColorScheme: lightScheme,
      darkColorScheme: darkScheme,
    );
    for (final weight in FontWeight.values) {
      final themes = AppTheme.resolve(
        fontFamily: AppFonts.systemFont,
        fontWeight: weight,
        lightColorScheme: lightScheme,
        darkColorScheme: darkScheme,
      );
      for (final pair in [
        (themes.light, original.light),
        (themes.dark, original.dark),
      ]) {
        expect(pair.$1.colorScheme, pair.$2.colorScheme);
        expect(pair.$1.primaryTextTheme, pair.$2.primaryTextTheme);
        if (weight != FontWeight.w400) {
          final text = pair.$1.textTheme;
          for (final style in [
            text.displayLarge,
            text.displayMedium,
            text.displaySmall,
            text.headlineLarge,
            text.headlineMedium,
            text.headlineSmall,
            text.titleLarge,
            text.titleMedium,
            text.titleSmall,
            text.bodyLarge,
            text.bodyMedium,
            text.bodySmall,
            text.labelLarge,
            text.labelMedium,
            text.labelSmall,
          ]) {
            expect(style?.fontWeight, weight);
          }
        }
      }
    }
    final restored = AppTheme.resolve(
      fontFamily: AppFonts.systemFont,
      fontWeight: FontWeight.w400,
      lightColorScheme: lightScheme,
      darkColorScheme: darkScheme,
    );
    expect(identical(restored.light, original.light), isTrue);
    expect(identical(restored.dark, original.dark), isTrue);
    expect(
      restored.light.textTheme,
      ThemeData(colorScheme: lightScheme).textTheme,
    );
  });

  test('changing or disabling dynamic colors does not retain stale bases', () {
    final defaults = AppTheme.resolve(
      fontFamily: AppFonts.systemFont,
      fontWeight: FontWeight.w400,
    );
    final scheme = ColorScheme.fromSeed(seedColor: Colors.purple);
    for (final schemes in [(scheme, null), (null, scheme), (null, null)]) {
      final themes = AppTheme.resolve(
        fontFamily: AppFonts.systemFont,
        fontWeight: FontWeight.w400,
        lightColorScheme: schemes.$1,
        darkColorScheme: schemes.$2,
      );
      expect(themes.light.brightness, Brightness.light);
      expect(themes.dark.brightness, Brightness.dark);
      expect(
        themes.light.colorScheme,
        schemes.$1 ?? defaults.light.colorScheme,
      );
      expect(
        themes.dark.colorScheme,
        schemes.$2?.copyWith(brightness: Brightness.dark) ??
            defaults.dark.colorScheme,
      );
      if (schemes.$1 == null) expect(themes.light, defaults.light);
      if (schemes.$2 == null) expect(themes.dark, defaults.dark);
    }
  });

  test('dynamic Material 3 color schemes are applied to both themes', () {
    final lightScheme = ColorScheme.fromSeed(
      seedColor: Colors.green,
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: Colors.orange,
      brightness: Brightness.dark,
    );

    final themes = AppTheme.resolve(
      fontFamily: AppFonts.systemFont,
      fontWeight: FontWeight.w400,
      lightColorScheme: lightScheme,
      darkColorScheme: darkScheme,
    );

    expect(themes.light.useMaterial3, isTrue);
    expect(themes.dark.useMaterial3, isTrue);
    expect(themes.light.colorScheme.primary, lightScheme.primary);
    expect(themes.dark.colorScheme.primary, darkScheme.primary);
    expect(themes.light.scaffoldBackgroundColor, lightScheme.surface);
    expect(themes.dark.scaffoldBackgroundColor, darkScheme.surface);
  });
}
