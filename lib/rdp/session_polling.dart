import 'frame_rate.dart';

/// Keeps control/clipboard latency independent of the display refresh rate.
/// Native textures still need a cursor poll, but not high-rate status reads.
class SessionPolling {
  SessionPolling({required this.visible, required this.frameRate});

  bool visible;
  int frameRate;
  int _nextControl = 0, _nextFrame = 0;
  static const foregroundControl = Duration(milliseconds: 33);
  static const backgroundControl = Duration(milliseconds: 100);

  Duration get interval {
    if (!visible) return backgroundControl;
    final frame = FrameRatePolicy.interval(frameRate);
    return frame < foregroundControl ? frame : foregroundControl;
  }

  void reset() {
    _nextControl = 0;
    _nextFrame = 0;
  }

  ({bool control, bool frame}) poll(int now) {
    final controlInterval =
        (visible ? foregroundControl : backgroundControl).inMicroseconds;
    final control = now >= _nextControl;
    if (control) {
      _nextControl = _advance(_nextControl, now, controlInterval);
    }
    final frame = visible && now >= _nextFrame;
    if (frame) {
      _nextFrame = _advance(
        _nextFrame,
        now,
        FrameRatePolicy.interval(frameRate).inMicroseconds,
      );
    }
    return (control: control, frame: frame);
  }

  // Dart timers can round down (8.333 ms -> 8 ms). Pace against a monotonic
  // deadline and drop missed slots rather than accumulating catch-up work.
  static int _advance(int deadline, int now, int interval) {
    if (deadline == 0 || now - deadline > interval) deadline = now;
    return deadline + interval;
  }
}
