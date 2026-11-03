import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';

class _Worker {
  late SendPort events;

  Future<void> launch(Map<String, dynamic> init) async {
    final commands = ReceivePort();
    events = init['events'] as SendPort;
    commands.listen((dynamic message) {
      if (message is List && message.first == 'stop') {
        events.send({'type': 'done'});
        commands.close();
      }
    });
    events.send(commands.sendPort);
    events.send({'type': 'features', 'value': 4});
    events.send({
      'type': 'state',
      'state': SessionState.connected.index,
      'error': '',
      'fingerprint': '',
      'version': 'test',
    });
  }

  void backend(int value) =>
      events.send({'type': 'decoderBackend', 'value': value});
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const profile = ConnectionProfile(
    id: 'backend',
    name: 'Test',
    host: '192.0.2.1',
  );

  test(
    'decoder changes notify once and reconnect clears the previous backend',
    () async {
      final worker = _Worker();
      final session = RdpSession(profile, workerLauncher: worker.launch);
      try {
        await session.connect(password: '');
        await _until(() => session.state == SessionState.connected);
        final values = <int>[];
        final changed = Completer<void>();
        void listener() {
          values.add(session.decoderBackend);
          if (values.length == 4) changed.complete();
        }

        session.addListener(listener);
        for (final value in [0, 2, 2, 3, 3, 1, 1, 0]) {
          worker.backend(value);
        }
        await changed.future.timeout(const Duration(seconds: 5));
        expect(values, [2, 3, 1, 0]);
        session.removeListener(listener);

        worker.backend(2);
        await _until(() => session.decoderBackend == 2);
        await session.connect(password: '');
        await _until(() => session.state == SessionState.connected);
        expect(session.hasDecodedAvc, isTrue);
        expect(session.decoderBackend, 0);
      } finally {
        await session.close();
        session.dispose();
      }
    },
  );

  test(
    'legacy worker without backend events keeps H.264 backend unknown',
    () async {
      final worker = _Worker();
      final session = RdpSession(profile, workerLauncher: worker.launch);
      try {
        await session.connect(password: '');
        await _until(() => session.state == SessionState.connected);
        expect(session.hasDecodedAvc, isTrue);
        expect(
          session.decoderBackend,
          0,
          reason: 'H.264 capability alone must not imply a CPU decoder',
        );
      } finally {
        await session.close();
        session.dispose();
      }
    },
  );
}
