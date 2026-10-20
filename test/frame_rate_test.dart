import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/frame_rate.dart';
import 'package:lrdp/rdp/native_video.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/remote_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(NativeVideo.channel, null);
    messenger.setMockMethodCallHandler(DisplayRefresh.channel, null);
  });

  test(
    'refresh policy honors display, explicit caps and unavailable display data',
    () {
      for (final rate in [60, 90, 120, 144, 165, 240]) {
        expect(FrameRatePolicy.effective(rate.toDouble(), 0), rate);
      }
      expect(FrameRatePolicy.effective(144, 120), 120);
      expect(FrameRatePolicy.effective(60, 240), 60);
      expect(FrameRatePolicy.effective(59.94, 0), 60);
      expect(FrameRatePolicy.effective(double.nan, 0), 60);
      expect(FrameRatePolicy.effective(0, 0), 60);
      expect(FrameRatePolicy.effective(0, 144), 144);
      expect(FrameRatePolicy.effective(360, 0), 240);
      expect(FrameRatePolicy.interval(120).inMicroseconds, 8333);
      expect(FrameRatePolicy.interval(240).inMicroseconds, 4167);
    },
  );

  testWidgets(
    'display and cap changes update a session in place and release the OS preference',
    (tester) async {
      final calls = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(DisplayRefresh.channel, (call) async {
        calls.add(Map<Object?, Object?>.from(call.arguments as Map));
        return null;
      });
      final session = RdpSession(
        const ConnectionProfile(id: 'refresh', name: 'Test', host: '192.0.2.1'),
      );
      session.state = SessionState.connected;
      final display = tester.view.display;
      addTearDown(display.resetRefreshRate);
      Widget view(int limit) => MaterialApp(
        home: RemoteView(
          session: session,
          reconnect: () {},
          disconnect: () {},
          active: true,
          toggleFullscreen: () {},
          frameRateLimit: limit,
        ),
      );
      display.refreshRate = 120;
      await tester.pumpWidget(view(0));
      expect(session.targetFrameRate, 120);
      display.refreshRate = 144;
      await tester.pump();
      expect(session.targetFrameRate, 144);
      await tester.pumpWidget(view(90));
      expect(session.targetFrameRate, 90);
      expect(session.state, SessionState.connected);
      await tester.pumpWidget(const SizedBox());
      expect(calls.last['active'], false);
      expect(calls.last['token'], calls.first['token']);
      session.dispose();
    },
  );

  testWidgets(
    'native renderer receives the high rate and caps survive hide/resume',
    (tester) async {
      final calls = <(String, Map)>[];
      messenger.setMockMethodCallHandler(NativeVideo.channel, (call) async {
        calls.add((call.method, call.arguments as Map));
        if (call.method == 'create' || call.method == 'status') {
          return {'id': 12, 'width': 800, 'height': 600, 'failed': false};
        }
        return null;
      });
      final video = (await NativeVideo.create(
        2,
        frameRate: 144,
        changed: (_) {},
        failed: (_) {},
      ))!;
      expect(calls.first.$2['frameRate'], 144);
      await video.setVisible(false);
      await video.setFrameRate(120);
      await video.setVisible(true);
      expect(video.frameRate, 120);
      expect(
        calls.where((call) => call.$1 == 'frameRate').single.$2['frameRate'],
        120,
      );
      await video.dispose();
      final count = calls.length;
      await video.setFrameRate(240);
      expect(calls.length, count);
    },
  );
}
