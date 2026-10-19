import 'dart:async';
import 'dart:ui' as ui;
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Refresh in place so a system appearance change never recreates sessions.
class SystemColors extends StatefulWidget {
  const SystemColors({super.key, required this.enabled, required this.builder});
  final bool enabled;
  final Widget Function(ColorScheme? light, ColorScheme? dark) builder;

  @override
  State<SystemColors> createState() => _SystemColorsState();
}

class _SystemColorsState extends State<SystemColors>
    with WidgetsBindingObserver {
  ColorScheme? _light, _dark;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant SystemColors oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) unawaited(_refresh());
  }

  @override
  void didChangePlatformBrightness() => unawaited(_refresh());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    if (event.state == ui.ViewFocusState.focused) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final request = ++_request;
    if (!widget.enabled) return;
    ColorScheme? light, dark;
    try {
      final palette = await DynamicColorPlugin.getCorePalette();
      if (palette != null) {
        light = palette.toColorScheme();
        dark = palette.toColorScheme(brightness: Brightness.dark);
      }
    } on PlatformException {
      // Accent color is also available on systems without an Android palette.
    }
    if (light == null) {
      try {
        final accent = await DynamicColorPlugin.getAccentColor();
        if (accent != null) {
          light = ColorScheme.fromSeed(seedColor: accent);
          dark = ColorScheme.fromSeed(
            seedColor: accent,
            brightness: Brightness.dark,
          );
        }
      } on PlatformException {
        // Unsupported/unavailable system colors use the application's palette.
      }
    }
    if (!mounted || request != _request || !widget.enabled) return;
    if (_light != light || _dark != dark) {
      setState(() {
        _light = light;
        _dark = dark;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    widget.enabled ? _light : null,
    widget.enabled ? _dark : null,
  );
}
