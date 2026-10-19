import 'package:flutter/services.dart';

class FrameRatePolicy {
  static int effective(double displayRate, int limit) {
    final screen = displayRate.isFinite && displayRate >= 1
        ? displayRate
        : (limit > 0 ? limit.toDouble() : 60.0);
    final cap = limit == 0 ? 240 : limit.clamp(1, 240);
    return screen.round().clamp(1, cap);
  }

  static Duration interval(int rate) =>
      Duration(microseconds: (1000000 / rate.clamp(1, 240)).round());
}

/// Android's display preference is scoped to the visible session. A token
/// prevents an outgoing view's late release from undoing the incoming view.
class DisplayRefresh {
  static const channel = OptionalMethodChannel('dev.lrdp/display');
  static int _serial = 0;
  static int allocate() => ++_serial;

  static Future<void> request(
    int token, {
    required bool active,
    required int limit,
  }) async {
    try {
      await channel.invokeMethod<void>('frameRate', {
        'token': token,
        'active': active,
        'limit': limit,
      });
    } on PlatformException {
      // OS policy/battery saving may refuse the request; normal rendering works.
    }
  }
}
