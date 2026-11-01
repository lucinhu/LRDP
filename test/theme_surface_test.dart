import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/ui/theme.dart';

/// Largest difference between the RGB channels of [color]. A value of 0 means
/// the color is perfectly grey (no hue); anything above ~3 is a visible tint.
int channelSpread(Color color) {
  final argb = color.toARGB32();
  final channels = [(argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF];
  return channels.reduce(math.max) - channels.reduce(math.min);
}

double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Neutral roles that must never carry the seed/accent hue.
Map<String, Color> neutralRoles(ColorScheme scheme) => {
  'surface': scheme.surface,
  'surfaceDim': scheme.surfaceDim,
  'surfaceBright': scheme.surfaceBright,
  'surfaceContainerLowest': scheme.surfaceContainerLowest,
  'surfaceContainerLow': scheme.surfaceContainerLow,
  'surfaceContainer': scheme.surfaceContainer,
  'surfaceContainerHigh': scheme.surfaceContainerHigh,
  'surfaceContainerHighest': scheme.surfaceContainerHighest,
  'onSurface': scheme.onSurface,
  'onSurfaceVariant': scheme.onSurfaceVariant,
  'outline': scheme.outline,
  'outlineVariant': scheme.outlineVariant,
  'inverseSurface': scheme.inverseSurface,
  'onInverseSurface': scheme.onInverseSurface,
};

void expectNeutral(Map<String, Color> roles) {
  roles.forEach((role, color) {
    expect(
      channelSpread(color),
      lessThanOrEqualTo(3),
      reason: '$role ${color.toARGB32().toRadixString(16)} has a hue tint',
    );
  });
}

const _surfaceContainerRoles = [
  'surfaceContainerLow',
  'surfaceContainer',
  'surfaceContainerHigh',
  'surfaceContainerHighest',
];

void main() {
  group('light theme', () {
    test('surfaces are neutral white without a tonal tint', () {
      final theme = appTheme(Brightness.light);
      final scheme = theme.colorScheme;

      expect(scheme.brightness, Brightness.light);
      expect(scheme.surface, Colors.white);
      expect(scheme.surfaceContainerLowest, Colors.white);
      expect(
        scheme.surfaceContainerLowest.computeLuminance(),
        greaterThan(.98),
      );
      expect(scheme.surfaceBright.computeLuminance(), greaterThan(.98));
      expectNeutral(neutralRoles(scheme));

      // Elevation steps remain ordered even though they are hue-free.
      final lows = scheme.surfaceContainerLow.computeLuminance();
      final base = scheme.surfaceContainer.computeLuminance();
      final high = scheme.surfaceContainerHigh.computeLuminance();
      final highest = scheme.surfaceContainerHighest.computeLuminance();
      expect(lows, greaterThan(base));
      expect(base, greaterThan(high));
      expect(high, greaterThan(highest));
      expect(
        scheme.surfaceDim.computeLuminance(),
        lessThan(scheme.surface.computeLuminance()),
      );
    });

    test('scaffold, app bar, cards and dialogs are crisp white-ish', () {
      final theme = appTheme(Brightness.light);

      expect(theme.scaffoldBackgroundColor, canvas);
      expect(channelSpread(canvas), lessThanOrEqualTo(2));
      expect(canvas.computeLuminance(), greaterThan(.9));
      // The old grey-green canvas is gone.
      expect(theme.scaffoldBackgroundColor, isNot(const Color(0xFFF4F6F3)));

      expect(theme.appBarTheme.backgroundColor, canvas);
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
      expect(theme.colorScheme.surfaceTint, Colors.transparent);

      expect(theme.cardTheme.color, Colors.white);

      final dialog = theme.dialogTheme;
      final dialogBackground = dialog.backgroundColor!;
      expect(dialogBackground.computeLuminance(), greaterThan(.95));
      expect(channelSpread(dialogBackground), lessThanOrEqualTo(3));
      expect(dialog.surfaceTintColor, Colors.transparent);
      expect(dialog.shape, isA<RoundedRectangleBorder>());
      expect(
        (dialog.shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(24),
      );
    });

    test('text and outline roles keep readable neutral contrast', () {
      final scheme = appTheme(Brightness.light).colorScheme;

      expect(contrastRatio(scheme.onSurface, scheme.surface), greaterThan(7));
      expect(
        contrastRatio(scheme.onSurfaceVariant, scheme.surface),
        greaterThan(4.5),
      );
      expect(contrastRatio(scheme.outline, scheme.surface), greaterThan(3));
      expect(
        scheme.onSurface.computeLuminance(),
        lessThan(scheme.onSurfaceVariant.computeLuminance()),
      );
    });

    test('brand accents still come from the pine seed', () {
      final scheme = appTheme(Brightness.light).colorScheme;
      final seeded = ColorScheme.fromSeed(seedColor: pine);
      expect(scheme.primary, seeded.primary);
      expect(scheme.primaryContainer, seeded.primaryContainer);
      expect(scheme.secondaryContainer, seeded.secondaryContainer);
    });
  });

  group('system accent colors', () {
    for (final accent in [
      Colors.purple,
      Colors.orange,
      const Color(0xFF00A000),
    ]) {
      test(
        'accent ${accent.toARGB32().toRadixString(16)} keeps system primary but neutral surfaces',
        () {
          final system = ColorScheme.fromSeed(seedColor: accent);
          final theme = appTheme(Brightness.light, systemColors: system);
          final scheme = theme.colorScheme;
          final builtIn = appTheme(Brightness.light);

          // Mirrors test/appearance_test.dart: the seeded primary must survive.
          expect(scheme.primary, system.primary);
          expect(
            scheme.primary,
            ColorScheme.fromSeed(seedColor: accent).primary,
          );
          // Accent containers/error keep the system identity.
          expect(scheme.secondaryContainer, system.secondaryContainer);
          expect(scheme.tertiaryContainer, system.tertiaryContainer);
          expect(scheme.error, system.error);

          // Neutral roles are the app's neutral ramp, not the tinted system one.
          expectNeutral(neutralRoles(scheme));
          expect(neutralRoles(scheme), neutralRoles(builtIn.colorScheme));
          expect(scheme.surface, Colors.white);
          expect(scheme.surfaceTint, Colors.transparent);
          expect(theme.scaffoldBackgroundColor, canvas);
          expect(theme.cardTheme.color, Colors.white);
          expect(theme.dialogTheme.backgroundColor, Colors.white);
        },
      );
    }
  });

  group('dark theme', () {
    test('surfaces are neutral and dark with sensible contrast', () {
      final theme = appTheme(Brightness.dark);
      final scheme = theme.colorScheme;

      expect(scheme.brightness, Brightness.dark);
      expectNeutral(neutralRoles(scheme));
      expect(scheme.surface.computeLuminance(), lessThan(.05));
      expect(scheme.surfaceBright.computeLuminance(), greaterThan(.03));
      expect(scheme.surfaceDim.computeLuminance(), lessThan(.02));

      // Elevation steps ascend from lowest to highest.
      final steps = _surfaceContainerRoles
          .map((role) => neutralRoles(scheme)[role]!.computeLuminance())
          .toList();
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], greaterThan(steps[i - 1]));
      }

      expect(contrastRatio(scheme.onSurface, scheme.surface), greaterThan(7));
      expect(
        contrastRatio(scheme.onSurfaceVariant, scheme.surface),
        greaterThan(4.5),
      );

      expect(theme.scaffoldBackgroundColor.computeLuminance(), lessThan(.02));
      expect(
        channelSpread(theme.scaffoldBackgroundColor),
        lessThanOrEqualTo(2),
      );
      expect(theme.scaffoldBackgroundColor, isNot(const Color(0xFF101916)));
      expect(theme.appBarTheme.backgroundColor, theme.scaffoldBackgroundColor);
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
      expect(theme.cardTheme.color, scheme.surface);
      expect(theme.dialogTheme.backgroundColor, scheme.surfaceContainerHigh);
      expect(theme.dialogTheme.surfaceTintColor, Colors.transparent);
      expect(scheme.surfaceTint, Colors.transparent);
    });

    test('system dark scheme keeps its primary but neutral surfaces', () {
      final system = ColorScheme.fromSeed(
        seedColor: Colors.purple,
        brightness: Brightness.dark,
      );
      final theme = appTheme(Brightness.dark, systemColors: system);
      final scheme = theme.colorScheme;
      final builtIn = appTheme(Brightness.dark);

      expect(scheme.primary, system.primary);
      expect(scheme.secondaryContainer, system.secondaryContainer);
      expectNeutral(neutralRoles(scheme));
      expect(neutralRoles(scheme), neutralRoles(builtIn.colorScheme));
      expect(theme.scaffoldBackgroundColor, builtIn.scaffoldBackgroundColor);
      expect(scheme.surfaceTint, Colors.transparent);
    });
  });

  testWidgets('dialogs and cards paint the crisp neutral surfaces', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Card(child: SizedBox(width: 120, height: 40)),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          const Dialog(child: SizedBox(width: 120, height: 40)),
                    ),
                    child: const Text('open'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final cardColors = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(Card),
            matching: find.byType(Material),
          ),
        )
        .map((material) => material.color);
    expect(cardColors, contains(Colors.white));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final dialogColors = tester
        .widgetList<Material>(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.byType(Material),
          ),
        )
        .map((material) => material.color);
    expect(dialogColors, contains(Colors.white));
    expect(tester.takeException(), isNull);
  });
}
