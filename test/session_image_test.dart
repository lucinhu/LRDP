import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/clipboard_picture.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/image_clipboard.dart';

class ImageWorker {
  final events = <SendPort>[];
  final commands = <List>[];
  Future<void> launch(Map<String, dynamic> init) async {
    final receive = ReceivePort(), send = init['events'] as SendPort;
    events.add(send);
    receive.listen((dynamic message) {
      if (message is! List) return;
      commands.add(message);
      if (message.first == 'stop') {
        send.send({'type': 'done'});
        receive.close();
      }
    });
    send.send(receive.sendPort);
    send.send({
      'type': 'state',
      'state': SessionState.connected.index,
      'reason': SessionEndReason.none.index,
      'error': '',
      'fingerprint': '',
      'version': 'test',
    });
    send.send({'type': 'features', 'value': 17});
  }
}

Future<void> until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ready() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  RdpSession session(ImageWorker worker) => RdpSession(
    const ConnectionProfile(id: 'image', name: 'Test', host: '192.0.2.1'),
    workerLauncher: worker.launch,
  );
  Future<ClipboardPicture> picture() => ClipboardPicture.decode(
    Uint8List.fromList([255, 0, 0, 255]),
    kind: 3,
    width: 1,
    height: 1,
  );
  test(
    'image and text share one transaction; confirmation IDs and close are respected',
    () async {
      final worker = ImageWorker();
      // Use one owner for the connection, including preparation in a helper isolate.
      final target = session(worker);
      try {
        await target.connect(password: '');
        await until(() => target.imageClipboardSupported);
        final p = await picture();
        final pending = target.pastePicture(p);
        expect(target.pasteInProgress, true);
        expect(await target.paste('duplicate'), false);
        await until(() => worker.commands.any((c) => c.first == 'pasteImage'));
        final request = worker.commands.firstWhere(
          (c) => c.first == 'pasteImage',
        );
        worker.events.last.send({
          'type': 'clipboardImage',
          'kind': 1,
          'bytes': TransferableTypedData.fromList([p.png]),
        });
        await until(
          () => worker.commands.any((c) => c.first == 'imageClipboardAck'),
        );
        expect(
          target.remotePicture,
          isNull,
          reason: 'Older remote data cannot override a local paste',
        );
        expect(
          (request[2] as TransferableTypedData).materialize().asUint8List(),
          p.png,
        );
        expect(
          (request[3] as TransferableTypedData).materialize().asUint8List(),
          p.toDib(),
        );
        worker.events.last.send({
          'type': 'pasteResult',
          'id': request[1] + 1,
          'ok': true,
          'message': '',
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(target.pasteInProgress, true);
        worker.events.last.send({
          'type': 'pasteResult',
          'id': request[1],
          'ok': true,
          'message': '',
        });
        expect(await pending, true);
        final cancelled = target.pastePicture(p);
        await target.close();
        expect(await cancelled, false);
        expect(target.pasteInProgress, false);
      } finally {
        await target.close();
        target.dispose();
      }
    },
  );
  test(
    'older core capability disables image calls; close during preparation sends no data',
    () async {
      final worker = ImageWorker();
      final s = session(worker);
      try {
        await s.connect(password: '');
        await until(() => s.imageClipboardSupported);
        final p = await picture();
        s.features = 1;
        expect(await s.pastePicture(p), false);
        expect(worker.commands.where((c) => c.first == 'pasteImage'), isEmpty);
        s.features = 17;
        final pending = s.pastePicture(p);
        await s.close();
        expect(await pending, false);
        expect(worker.commands.where((c) => c.first == 'pasteImage'), isEmpty);
      } finally {
        await s.close();
        s.dispose();
      }
    },
  );
  test(
    'image mailbox acknowledges once, text supersedes image, reconnect rejects old events',
    () async {
      final worker = ImageWorker();
      final target = session(worker);
      final p = await picture();
      void sendImage(SendPort port) => port.send({
        'type': 'clipboardImage',
        'kind': 1,
        'bytes': TransferableTypedData.fromList([p.png]),
      });
      try {
        await target.connect(password: '');
        await until(() => target.imageClipboardSupported);
        sendImage(worker.events.last);
        await until(() => target.remotePicture != null);
        target.discardRemotePicture();
        target.discardRemotePicture();
        await until(
          () =>
              worker.commands
                  .where((c) => c.first == 'imageClipboardAck')
                  .length ==
              1,
        );
        sendImage(worker.events.last);
        await until(() => target.remotePicture != null);
        worker.events.last.send({'type': 'clipboard', 'text': 'new text'});
        await until(() => target.remoteClipboard == 'new text');
        expect(target.remotePicture, isNull);
        await until(
          () =>
              worker.commands
                  .where((c) => c.first == 'imageClipboardAck')
                  .length ==
              2,
        );
        await target.connect(password: '');
        await until(() => target.imageClipboardSupported);
        sendImage(worker.events.first);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(target.remotePicture, isNull);
      } finally {
        await target.close();
        target.dispose();
      }
    },
  );
  test(
    'inactive session guard prevents OS image publication after async conversion',
    () async {
      var writes = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ImageClipboard.channel, (call) async {
        writes++;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(ImageClipboard.channel, null),
      );
      expect(
        await ImageClipboard.write(await picture(), isCurrent: () => false),
        false,
      );
      expect(writes, 0);
    },
  );
}
