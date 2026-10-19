import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final port = Platform.environment['LRDP_FRAME_PORT'];
  testWidgets(
    'actual TLS frames exceed 60 fps without an unbounded decode queue',
    (tester) async {
      await tester.runAsync(() async {
        final directory = Directory.systemTemp.createTempSync(
          'lrdp-frame-client-',
        );
        final session = RdpSession(
          ConnectionProfile(
            id: 'frame-rate',
            name: 'Loopback',
            host: '127.0.0.1',
            port: int.parse(port!),
            width: 320,
            height: 240,
            nla: false,
          ),
          protocolDirectory: directory.path,
        );
        try {
          await session.connect(
            password: '',
            acceptedFingerprint: Platform.environment['LRDP_FRAME_PIN']!,
          );
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (!session.hasVideo && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(session.hasVideo, true, reason: session.error);
          final samples = <String, double>{};
          for (final rate in [30, 120, 240]) {
            session.setFrameRate(rate);
            await Future<void>.delayed(const Duration(milliseconds: 200));
            final count = session.decodedFrames;
            final watch = Stopwatch()..start();
            await Future<void>.delayed(const Duration(milliseconds: 1800));
            samples['$rate'] =
                (session.decodedFrames - count) *
                1000000 /
                watch.elapsedMicroseconds;
          }
          expect(samples['30']!, lessThan(42));
          expect(samples['120']!, greaterThan(70));
          expect(samples['120']!, lessThan(124));
          expect(samples['120']!, greaterThan(samples['30']! * 1.8));
          expect(samples['240']!, greaterThan(100));
          session.setVisible(false);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final hidden = session.decodedFrames;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(session.decodedFrames, hidden);
          session.setVisible(true);
          session.setFrameRate(120);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(session.decodedFrames, greaterThan(hidden));
          final bytes = await session.image!.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(bytes!.getUint8(0), 0x75);
          expect(bytes.getUint8(1) * 256 + bytes.getUint8(2), greaterThan(100));
          session.scan(0x1e, true);
          session.scan(0x1e, false);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          File(Platform.environment['LRDP_FRAME_VERDICT']!).writeAsStringSync(
            jsonEncode({
              'passed': true,
              'actual_decoded_fps': samples,
              'path':
                  'real TLS RDP + worker + Flutter CPU image decode; no physical display',
              'background_paused': true,
              'resumed': true,
            }),
          );
        } finally {
          await session.close();
          session.dispose();
          directory.deleteSync(recursive: true);
        }
      });
    },
    skip: port == null,
  );
}
