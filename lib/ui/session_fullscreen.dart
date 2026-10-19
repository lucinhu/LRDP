import 'package:flutter/services.dart';

/// Serialize platform requests so a late enter cannot override a later exit.
class SessionFullscreen {
  static const _channel = OptionalMethodChannel('dev.lrdp/window');
  Future<void> _pending = Future.value();
  (bool, TargetPlatform)? _requested;

  void set(bool enabled, TargetPlatform platform, {bool refresh = false}) {
    if (!refresh && _requested == (enabled, platform)) return;
    _requested = (enabled, platform);
    _pending = _pending.then((_) async {
      try {
        if (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS) {
          await SystemChrome.setEnabledSystemUIMode(
            enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
          );
        } else {
          await _channel.invokeMethod<void>('fullscreen', enabled);
        }
      } on PlatformException {
        // The in-window layout remains available if the platform rejects it.
      }
    });
  }
}
