import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';

void main() {
  testWidgets(
    'real RDP certificate flow, isolate frame decode and shutdown',
    (tester) async {
      await tester.runAsync(() async {
        final session = RdpSession(
          ConnectionProfile(
            id: 'loopback',
            name: 'Private test',
            host: '127.0.0.1',
            port: int.parse(Platform.environment['LRDP_TEST_PORT']!),
            username: 'test',
            nla: false,
          ),
        );
        Future<void> waitFor(bool Function() predicate) async {
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (!predicate() && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          expect(
            predicate(),
            true,
            reason: '${session.state}: ${session.error}',
          );
        }

        try {
          await session.connect(password: '');
          await waitFor(() => !session.isActive);
          expect(session.state, SessionState.certificateRequired);
          final fingerprint = session.fingerprint;
          expect(fingerprint.replaceAll(':', '').length, 64);
          await session.connect(password: '', acceptedFingerprint: fingerprint);
          await waitFor(
            () => session.image != null || session.state == SessionState.failed,
          );
          expect(session.state, SessionState.connected);
          expect(session.image!.width, 1280);
          expect(session.image!.height, 800);
          if (Platform.environment['LRDP_TEST_CODEC'] == 'avc420') {
            final wire = File(Platform.environment['LRDP_AVC_WIRE_LOG']!);
            await waitFor(
              () =>
                  wire.existsSync() &&
                  wire.readAsStringSync().contains(
                    'Got GFX RDPGFX_CODECID_AVC420',
                  ),
            );
            final changed = await Process.run('xsetroot', [
              '-solid',
              '#2a8465',
            ]);
            expect(changed.exitCode, 0);
            final deadline = DateTime.now().add(const Duration(seconds: 20));
            var verified = false;
            while (!verified && DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              final frame = session.image!.clone();
              try {
                final bytes = (await frame.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                final offset = (400 * frame.width + 640) * 4;
                const rgba = [42, 132, 101, 255];
                verified =
                    List.generate(
                      3,
                      (i) => (bytes.getUint8(offset + i) - rgba[i]).abs() <= 4,
                    ).every((v) => v) &&
                    bytes.getUint8(offset + 3) == 255;
              } finally {
                frame.dispose();
              }
            }
            expect(
              verified,
              isTrue,
              reason: 'Decoded AVC420 frame after wire capability activation',
            );
          }
          session.mouse(0x0800, 100, 100);
          session.chord([0x1d, 0x2e]);
          session.text('LRDP 中文输入验证');
          session.text('x' * 4000);
          // Closing during queued text must never access a destroyed native pointer.
          await Future.wait([session.close(), session.close()]);
          expect(session.state, SessionState.closed);
        } finally {
          await session.close();
          session.dispose();
        }
      });
    },
    skip: Platform.environment['LRDP_TEST_PORT'] == null,
  );
}
