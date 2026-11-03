import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/rdp/session_polling.dart';

void main() {
  test('high refresh preserves frames without high-rate status queries', () {
    final polling = SessionPolling(visible: true, frameRate: 240);
    var controls = 0, frames = 0;
    // Exercise millisecond timer rounding, as with real Dart timers.
    for (var now = 0; now < 1000000; now += 4000) {
      final due = polling.poll(now);
      if (due.control) controls++;
      if (due.frame) frames++;
    }
    expect(controls, inInclusiveRange(30, 31));
    expect(frames, inInclusiveRange(238, 240));
  });

  test('a 1 fps display does not delay control or Unicode queue work', () {
    final polling = SessionPolling(visible: true, frameRate: 1);
    expect(polling.interval, const Duration(milliseconds: 33));
    var controls = 0, frames = 0;
    for (var now = 0; now < 1000000; now += 33000) {
      final due = polling.poll(now);
      if (due.control) controls++;
      if (due.frame) frames++;
    }
    expect(controls, 31);
    expect(frames, 1);
  });

  test('hidden sessions use 10 Hz controls and resume without catch-up', () {
    final polling = SessionPolling(visible: false, frameRate: 144);
    expect(polling.interval, const Duration(milliseconds: 100));
    var controls = 0;
    for (var now = 0; now < 1000000; now += 1000) {
      final due = polling.poll(now);
      if (due.control) controls++;
      expect(due.frame, false);
    }
    expect(controls, 10);
    polling
      ..visible = true
      ..reset();
    expect(polling.poll(2000000), (control: true, frame: true));
    expect(polling.poll(2000000), (control: false, frame: false));
    // A long stall produces one current frame, without replaying old slots.
    expect(polling.poll(9000000), (control: true, frame: true));
    expect(polling.poll(9000000), (control: false, frame: false));
  });
}
