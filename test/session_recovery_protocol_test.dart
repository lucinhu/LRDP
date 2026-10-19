import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/rdp/session_recovery.dart';

void main() {
  testWidgets(
    'real TLS drop, fresh connection, cancellation and certificate rotation',
    (tester) async {
      await tester.runAsync(() async {
        final controlPath = Platform.environment['LRDP_RECOVERY_CONTROL']!;
        Future<int> control(String command) async {
          final socket = await Socket.connect(
            InternetAddress(controlPath, type: InternetAddressType.unix),
            0,
          );
          try {
            socket.write('$command\n');
            await socket.flush();
            final line = await socket
                .cast<List<int>>()
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first;
            return (jsonDecode(line) as Map)['connections'] as int;
          } finally {
            socket.destroy();
          }
        }

        final session = RdpSession(
          ConnectionProfile(
            id: 'fault',
            name: 'Fault injection',
            host: '127.0.0.1',
            port: int.parse(Platform.environment['LRDP_TEST_PORT']!),
            username: 'test',
            nla: false,
          ),
        );
        String pin = '';
        var retries = 0;
        final recovery = SessionRecovery(
          session,
          reconnect: () async {
            retries++;
            await session.connect(password: '', acceptedFingerprint: pin);
          },
        );
        Future<void> until(bool Function() predicate, String label) async {
          final deadline = DateTime.now().add(const Duration(seconds: 25));
          while (!predicate() && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(
            predicate(),
            isTrue,
            reason:
                '$label: ${session.state}/${session.endReason} code=${session.errorCode} ${session.error}',
          );
        }

        try {
          await session.connect(password: '');
          await until(
            () => session.state == SessionState.certificateRequired,
            'Initial TLS certificate',
          );
          expect(session.endReason, SessionEndReason.certificate);
          expect(retries, 0);
          pin = session.fingerprint;
          await session.connect(password: '', acceptedFingerprint: pin);
          await until(() => session.image != null, 'Actual initial RDP frame');
          final connected = session.connectedAt;
          await control('drop');
          await until(
            () => recovery.pending,
            'Transport classification after TCP EOF',
          );
          expect(session.endReason, SessionEndReason.transport);
          await until(
            () =>
                retries == 1 &&
                session.image != null &&
                session.connectedAt != connected,
            'Fresh TLS RDP reconnect and decoded frame',
          );
          expect(session.state, SessionState.connected);
          final afterRecovery = await control('pause');
          await until(() => recovery.pending, 'Second loss');
          recovery.cancel();
          await Future<void>.delayed(const Duration(seconds: 3));
          expect(
            await control('stats'),
            afterRecovery,
            reason: 'Cancel must prevent any new network handshake',
          );
          await control('resume');
          recovery.reset();
          await session.connect(password: '', acceptedFingerprint: pin);
          await until(
            () =>
                session.image != null &&
                session.state == SessionState.connected,
            'Manual reconnect',
          );
          await control('rotate');
          await until(
            () => session.state == SessionState.certificateRequired,
            'Changed certificate blocks automatic reconnect',
          );
          expect(session.endReason, SessionEndReason.certificate);
          expect(session.fingerprint, isNot(pin));
          expect(recovery.pending, isFalse);
          final count = await control('stats');
          await Future<void>.delayed(const Duration(seconds: 3));
          expect(
            await control('stats'),
            count,
            reason: 'Changed certificate must not trigger retry loop',
          );
          await session.close();
          expect(session.endReason, SessionEndReason.local);
          stdout.writeln(
            'PASS: real EOF -> bounded recovery -> actual RDP image; cancel prevents handshakes; changed TLS certificate halts retries',
          );
        } finally {
          recovery.dispose();
          await session.close();
          session.dispose();
        }
      });
    },
    skip: Platform.environment['LRDP_RECOVERY_CONTROL'] == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
