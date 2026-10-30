import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_cursor.dart';
import 'package:lrdp/rdp/rdp_session.dart';

/// Drives the real session event loop through a fake worker so cursor
/// notification behavior can be checked without a server.
class CursorWorker {
  late SendPort events;
  var positionSerial = 0, shapeSerial = 0;
  int kind = RdpCursorKind.system.index;

  Future<void> launch(Map<String, dynamic> init) async {
    final receive = ReceivePort();
    events = init['events'] as SendPort;
    receive.listen((dynamic message) {
      if (message is List && message.isNotEmpty && message.first == 'stop') {
        events.send({'type': 'done'});
        receive.close();
      }
    });
    events.send(receive.sendPort);
    events.send({
      'type': 'state',
      'state': SessionState.connected.index,
      'reason': SessionEndReason.none.index,
      'error': '',
      'fingerprint': '',
      'version': 'test',
    });
    events.send({'type': 'features', 'value': 0});
  }

  void move(int x, int y) {
    positionSerial++;
    events.send({
      'type': 'cursor',
      'info': [kind, 0, 0, 0, 0, x, y, positionSerial, shapeSerial],
      'pixels': null,
    });
  }

  void reshape(RdpCursorKind next) {
    kind = next.index;
    shapeSerial++;
    events.send({
      'type': 'cursor',
      'info': [kind, 0, 0, 0, 0, 0, 0, positionSerial, shapeSerial],
      'pixels': null,
    });
  }
}

Future<void> until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ready() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'position-only cursor updates do not notify session listeners',
    () async {
      final worker = CursorWorker();
      final session = RdpSession(
        const ConnectionProfile(id: 'cursor', name: 'Test', host: '192.0.2.1'),
        workerLauncher: worker.launch,
      );
      try {
        await session.connect(password: '');
        await until(() => session.state == SessionState.connected);
        // Let connect-time notifications settle before counting.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        var notifications = 0;
        final moved = <int>[];
        session.addListener(() => notifications++);
        session.cursorMoved.addListener(
          () => moved.add(session.cursorMoved.value),
        );

        worker.move(120, 80);
        await until(() => session.cursor.x == 120 && session.cursor.y == 80);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          notifications,
          0,
          reason: 'A pointer move must not rebuild every session listener',
        );
        expect(moved, isNotEmpty);
        expect(moved.last, worker.positionSerial);

        final beforeShape = notifications;
        worker.reshape(RdpCursorKind.hidden);
        await until(() => session.cursor.kind == RdpCursorKind.hidden);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          notifications,
          greaterThan(beforeShape),
          reason: 'A cursor shape change still notifies listeners',
        );
      } finally {
        await session.close();
        session.dispose();
      }
    },
  );
}
