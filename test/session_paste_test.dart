import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue);
}

class PasteWorker {
  final events = <SendPort>[];
  final requests = <List<dynamic>>[];
  int stops = 0;
  Future<void> launch(Map<String, dynamic> init) async {
    final port = ReceivePort();
    final target = init['events'] as SendPort;
    events.add(target);
    port.listen((dynamic message) {
      if (message is! List) return;
      if (message.first == 'stop') {
        stops++;
        target.send({'type': 'done'});
        port.close();
      } else if (message.first == 'paste') {
        requests.add(message.cast<dynamic>());
      }
    });
    target.send(port.sendPort);
    target.send({
      'type': 'state',
      'state': SessionState.connected.index,
      'reason': SessionEndReason.none.index,
      'error': '',
      'fingerprint': '',
      'version': 'test',
    });
    target.send({'type': 'features', 'value': 1});
  }
}

void main() {
  const profile = ConnectionProfile(
    id: 'paste',
    name: 'Test',
    host: '192.0.2.1',
  );
  test(
    'one paste at a time, matching confirmation and close settle all callers',
    () async {
      final worker = PasteWorker();
      final session = RdpSession(profile, workerLauncher: worker.launch);
      try {
        await session.connect(password: '');
        await until(() => session.clipboardSupported);
        final first = session.paste('中文');
        expect(await session.paste('duplicate'), isFalse);
        await until(() => worker.requests.isNotEmpty);
        final id = worker.requests.single[1] as int;
        worker.events.last.send({
          'type': 'pasteResult',
          'id': id + 1,
          'ok': true,
          'message': '',
        });
        await Future<void>.delayed(Duration.zero);
        expect(session.pasteInProgress, isTrue);
        worker.events.last.send({
          'type': 'pasteResult',
          'id': id,
          'ok': true,
          'message': '',
        });
        expect(await first, isTrue);
        expect(session.pasteInProgress, isFalse);
        final cancelled = session.paste('尚未确认');
        await Future.wait([session.close(), session.close()]);
        expect(await cancelled, isFalse);
        expect(worker.stops, 1);
      } finally {
        await session.close();
        session.dispose();
      }
    },
  );
  test(
    'unavailable clipboard and invalid text never reach the worker',
    () async {
      final worker = PasteWorker();
      final session = RdpSession(profile, workerLauncher: worker.launch);
      try {
        await session.connect(password: '');
        await until(() => session.clipboardSupported);
        session.features = 0;
        expect(await session.paste('中文'), isFalse);
        session.features = 1;
        for (final text in ['', 'abc\u0000partial', 'x' * 16385]) {
          expect(await session.paste(text), isFalse);
        }
        expect(worker.requests, isEmpty);
        expect(session.pasteInProgress, isFalse);
      } finally {
        await session.close();
        session.dispose();
      }
    },
  );
  test('reconnect cancels old paste and ignores stale confirmations', () async {
    final worker = PasteWorker();
    final session = RdpSession(profile, workerLauncher: worker.launch);
    try {
      await session.connect(password: '');
      await until(() => session.clipboardSupported);
      final old = session.paste('旧会话');
      await until(() => worker.requests.length == 1);
      await session.connect(password: '');
      expect(await old, isFalse);
      await until(() => session.clipboardSupported);
      final current = session.paste('新会话');
      await until(() => worker.requests.length == 2);
      worker.events.first.send({
        'type': 'pasteResult',
        'id': worker.requests.first[1],
        'ok': true,
        'message': '',
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.pasteInProgress, isTrue);
      worker.events.last.send({
        'type': 'pasteResult',
        'id': worker.requests.last[1],
        'ok': true,
        'message': '',
      });
      expect(await current, isTrue);
    } finally {
      await session.close();
      session.dispose();
    }
  });
}
