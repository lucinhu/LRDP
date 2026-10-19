import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final port = Platform.environment['LRDP_RESOLUTION_PORT'];
  testWidgets(
    'automatic handshake and debounced DISP resize retain the connection',
    (tester) async {
      await tester.runAsync(() async {
        final directory = Directory.systemTemp.createTempSync(
          'lrdp-size-client-',
        );
        final session = RdpSession(
          ConnectionProfile(
            id: 'size',
            name: 'Loopback',
            host: '127.0.0.1',
            port: int.parse(port!),
            nla: false,
          ),
          protocolDirectory: directory.path,
        );
        Future<void> waitFor(bool Function() condition) async {
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (!condition() && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(condition(), isTrue, reason: session.error);
        }

        try {
          session.setViewportSize(803, 602);
          await session.connect(
            password: '',
            acceptedFingerprint: Platform.environment['LRDP_RESOLUTION_PIN']!,
          );
          await waitFor(
            () => session.hasVideo && session.displayResizeSupported,
          );
          expect((session.desktopWidth, session.desktopHeight), (802, 602));
          final connection = session.connectedAt;
          session.setViewportSize(1200, 900);
          await Future<void>.delayed(const Duration(milliseconds: 150));
          session.setViewportSize(1001, 700);
          await waitFor(
            () => session.desktopWidth == 1000 && session.desktopHeight == 700,
          );
          // A background view must not submit display changes. Resume sends
          // only the final geometry and reuses the same TLS connection.
          session.setVisible(false);
          session.setViewportSize(1600, 1000);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          session.setViewportSize(721, 960);
          session.setVisible(true);
          await waitFor(
            () => session.desktopWidth == 720 && session.desktopHeight == 960,
          );
          expect(session.connectedAt, connection);
          expect(session.profile.width, 1280);
          expect(session.profile.height, 800);
          session.scan(0x1e, true);
          session.scan(0x1e, false);
          await Future<void>.delayed(const Duration(milliseconds: 150));
          File(
            Platform.environment['LRDP_RESOLUTION_VERDICT']!,
          ).writeAsStringSync(
            jsonEncode({
              'passed': true,
              'handshake': [802, 602],
              'resized_frames': [
                [1000, 700],
                [720, 960],
              ],
              'connection_reused': true,
              'background_deferred': true,
              'source':
                  'real TLS + initial settings + DISP PDUs + reactivated decoded frames',
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
