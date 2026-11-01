import 'package:flutter/material.dart';

const pine = Color(0xFF1B5E4B);
const mint = Color(0xFFBDE3C9);
const ink = Color(0xFF182D28);

/// Neutral near-white used behind cards and for app bars in light mode.
/// The brand identity lives in [pine]/[mint] accents, not in the neutral
/// surface ramp, so this stays hue-free instead of the old grey-green #F4F6F3.
const canvas = Color(0xFFF7F7F7);

/// Dark-mode canvas: neutral near-black, no green cast.
const _darkCanvas = Color(0xFF101010);

/// Hue-free surface/outline ramp.
///
/// Material 3 derives these roles from the seed (or system accent) tonal
/// palette, which tints every neutral step. Dialogs, the floating session
/// controls and the remote keyboard panel read as grey-green because of it, so
/// the app overrides those roles with the neutral values below while keeping
/// the seeded accent roles (primary/secondary/tertiary/error) intact.
class _NeutralRamp {
  const _NeutralRamp({
    required this.surface,
    required this.surfaceDim,
    required this.surfaceBright,
    required this.surfaceContainerLowest,
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.dialog,
  });

  final Color surface;
  final Color surfaceDim;
  final Color surfaceBright;
  final Color surfaceContainerLowest;
  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;
  final Color inverseSurface;
  final Color onInverseSurface;
  final Color dialog;
}

const _lightRamp = _NeutralRamp(
  surface: Color(0xFFFFFFFF),
  surfaceDim: Color(0xFFDEDEDE),
  surfaceBright: Color(0xFFFFFFFF),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF7F7F7),
  surfaceContainer: Color(0xFFF2F2F2),
  surfaceContainerHigh: Color(0xFFECECEC),
  surfaceContainerHighest: Color(0xFFE6E6E6),
  onSurface: Color(0xFF1B1B1B),
  onSurfaceVariant: Color(0xFF444444),
  outline: Color(0xFF7A7A7A),
  outlineVariant: Color(0xFFC7C7C7),
  inverseSurface: Color(0xFF313131),
  onInverseSurface: Color(0xFFF4F4F4),
  dialog: Color(0xFFFFFFFF),
);

const _darkRamp = _NeutralRamp(
  surface: Color(0xFF181818),
  surfaceDim: Color(0xFF111111),
  surfaceBright: Color(0xFF3A3A3A),
  surfaceContainerLowest: Color(0xFF0C0C0C),
  surfaceContainerLow: Color(0xFF1D1D1D),
  surfaceContainer: Color(0xFF202020),
  surfaceContainerHigh: Color(0xFF2A2A2A),
  surfaceContainerHighest: Color(0xFF333333),
  onSurface: Color(0xFFE6E6E6),
  onSurfaceVariant: Color(0xFFC2C2C2),
  outline: Color(0xFF909090),
  outlineVariant: Color(0xFF444444),
  inverseSurface: Color(0xFFE8E8E8),
  onInverseSurface: Color(0xFF2B2B2B),
  dialog: Color(0xFF2A2A2A),
);

/// Applies the neutral ramp on top of the seeded (or system-accent) scheme.
///
/// Only neutral roles are replaced: primary/secondary/tertiary, their
/// containers and error colors keep the seed/accent identity. The surface tint
/// is transparent so elevation never re-tints white surfaces.
ColorScheme _neutralScheme(Brightness brightness, ColorScheme? systemColors) {
  final ramp = brightness == Brightness.dark ? _darkRamp : _lightRamp;
  final base =
      systemColors ??
      ColorScheme.fromSeed(seedColor: pine, brightness: brightness);
  return base.copyWith(
    surface: ramp.surface,
    surfaceDim: ramp.surfaceDim,
    surfaceBright: ramp.surfaceBright,
    surfaceContainerLowest: ramp.surfaceContainerLowest,
    surfaceContainerLow: ramp.surfaceContainerLow,
    surfaceContainer: ramp.surfaceContainer,
    surfaceContainerHigh: ramp.surfaceContainerHigh,
    surfaceContainerHighest: ramp.surfaceContainerHighest,
    onSurface: ramp.onSurface,
    onSurfaceVariant: ramp.onSurfaceVariant,
    outline: ramp.outline,
    outlineVariant: ramp.outlineVariant,
    inverseSurface: ramp.inverseSurface,
    onInverseSurface: ramp.onInverseSurface,
    surfaceTint: Colors.transparent,
  );
}

ThemeData appTheme(Brightness brightness, {ColorScheme? systemColors}) {
  final dark = brightness == Brightness.dark;
  final scheme = _neutralScheme(brightness, systemColors);
  final ramp = dark ? _darkRamp : _lightRamp;
  final background = dark ? _darkCanvas : canvas;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    fontFamilyFallback: const [
      'Noto Sans CJK SC',
      'Microsoft YaHei',
      'PingFang SC',
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    textTheme: TextTheme(
      headlineLarge: TextStyle(
        fontSize: 32,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
        color: scheme.onSurface,
      ),
      headlineMedium: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -.7,
      ),
      titleLarge: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      titleMedium: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      bodyMedium: const TextStyle(fontSize: 14, height: 1.5),
      labelLarge: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: .5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: .5),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .45)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ramp.dialog,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .5),
      thickness: 1,
    ),
  );
}

class Brand extends StatelessWidget {
  const Brand({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Image.asset(
        'assets/branding/lrdp-128.png',
        width: 36,
        height: 36,
        excludeFromSemantics: true,
      ),
      if (!compact) ...[
        const SizedBox(width: 11),
        Text(
          'LRDP',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
      ],
    ],
  );
}
