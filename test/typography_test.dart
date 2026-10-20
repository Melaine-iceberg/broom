import 'package:broom/app.dart';
import 'package:broom/ui/broom_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('theme uses the bundled HarmonyOS Sans SC family everywhere', () {
    for (final brightness in Brightness.values) {
      final theme = buildBroomTheme(brightness);
      final textTheme = theme.textTheme;
      final styles = <String, TextStyle?>{
        'displayLarge': textTheme.displayLarge,
        'displayMedium': textTheme.displayMedium,
        'displaySmall': textTheme.displaySmall,
        'headlineLarge': textTheme.headlineLarge,
        'headlineMedium': textTheme.headlineMedium,
        'headlineSmall': textTheme.headlineSmall,
        'titleLarge': textTheme.titleLarge,
        'titleMedium': textTheme.titleMedium,
        'titleSmall': textTheme.titleSmall,
        'bodyLarge': textTheme.bodyLarge,
        'bodyMedium': textTheme.bodyMedium,
        'bodySmall': textTheme.bodySmall,
        'labelLarge': textTheme.labelLarge,
        'labelMedium': textTheme.labelMedium,
        'labelSmall': textTheme.labelSmall,
      };
      for (final entry in styles.entries) {
        expect(entry.value?.fontFamily, broomFontFamily, reason: entry.key);
        expect(
          entry.value?.fontFamilyFallback,
          broomFontFallback,
          reason: entry.key,
        );
      }
      expect(
        theme.filledButtonTheme.style?.textStyle?.resolve({})?.fontFamily,
        broomFontFamily,
      );
    }
  });
}
