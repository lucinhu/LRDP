import 'dart:async';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';

const profile = ConnectionProfile(id: 'race', name: 'Race', host: '192.0.2.1');

void main() {
  testWidgets(
    'close cancels a connect waiting for teardown before worker creation',
    (tester) async {
      await tester.runAsync(() async {
        var launched = 0;
        final session = RdpSession(
          profile,
          workerLauncher: (_) async {
            launched++;
          },
        );
        final connecting = session.connect(password: 'temporary');
        await session.close();
        await connecting;
        expect(launched, 0);
        expect(session.state, SessionState.closed);
        session.dispose();
      });
    },
  );

  testWidgets(
    'newest concurrent connect wins; late port is stopped; stale events ignored',
    (tester) async {
      await tester.runAsync(() async {
        final launched = <String>[];
        final ports = <ReceivePort>[];
        var stopped = 0;
        final ready = Completer<void>(), allowPort = Completer<void>();
        final session = RdpSession(
          profile,
          workerLauncher: (init) async {
            launched.add(init['fingerprint'] as String);
            final events = init['events'] as SendPort;
            final commands = ReceivePort();
            ports.add(commands);
            commands.listen((dynamic value) {
              if (value is List && value.first == 'stop') {
                stopped++;
                events.send({'type': 'done'});
                commands.close();
              }
            });
            ready.complete();
            await allowPort.future;
            events.send(commands.sendPort);
            events.send({
              'type': 'state',
              'state': SessionState.connected.index,
              'reason': SessionEndReason.none.index,
              'error': '',
              'fingerprint': '',
              'version': 'test',
            });
          },
        );
        final first = session.connect(
          password: 'one',
          acceptedFingerprint: 'old',
        );
        final second = session.connect(
          password: 'two',
          acceptedFingerprint: 'new',
        );
        await ready.future;
        final closing = session.close();
        allowPort.complete();
        await Future.wait([first, second, closing, session.close()]);
        expect(launched, ['new']);
        expect(stopped, 1);
        expect(session.state, SessionState.closed);
        expect(session.endReason, SessionEndReason.local);
        session.dispose();
        for (final port in ports) {
          port.close();
        }
      });
    },
  );

  testWidgets('disposal during worker startup still delivers cancellation', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final ready = Completer<void>(),
          gate = Completer<void>(),
          stopped = Completer<void>();
      final session = RdpSession(
        profile,
        workerLauncher: (init) async {
          final events = init['events'] as SendPort;
          final commands = ReceivePort();
          commands.listen((dynamic event) {
            if (event is List && event.first == 'stop') {
              events.send({'type': 'done'});
              commands.close();
              stopped.complete();
            }
          });
          ready.complete();
          await gate.future;
          events.send(commands.sendPort);
        },
      );
      final connecting = session.connect(password: 'temporary');
      await ready.future;
      session.dispose();
      gate.complete();
      await connecting;
      await stopped.future;
      await session.close();
      expect(session.state, SessionState.closed);
    });
  });
}
