import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';

class FileWorker {
  FileWorker({this.features = 33});
  final int features;
  final commands = <List>[];
  late SendPort events;
  Future<void> launch(Map<String, dynamic> init) async {
    final receive = ReceivePort();
    events = init['events'] as SendPort;
    receive.listen((dynamic message) {
      if (message is! List) return;
      commands.add(message);
      if (message.first == 'stop') {
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
    events.send({'type': 'features', 'value': features});
  }
}

Future<void> until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  RdpSession session(FileWorker worker) => RdpSession(
    const ConnectionProfile(id: 'files', name: 'Test', host: '192.0.2.1'),
    workerLauncher: worker.launch,
  );
  XFile source() =>
      XFile.fromData(Uint8List.fromList([0, 255, 128]), path: '中文.bin');
  test(
    'file paste reserves the shared transaction and cleans staged paths after confirmation',
    () async {
      final worker = FileWorker();
      final active = session(worker);
      try {
        await active.connect(password: '');
        await until(() => active.fileClipboardSupported);
        final paste = active.pasteFiles([source()]);
        expect(active.pasteInProgress, true);
        expect(await active.paste('cannot replace files'), false);
        await until(() => worker.commands.any((c) => c.first == 'pasteFiles'));
        final request = worker.commands.firstWhere(
          (c) => c.first == 'pasteFiles',
        );
        final paths = (request[2] as List).cast<String>();
        expect(await File(paths.single).readAsBytes(), [0, 255, 128]);
        worker.events.send({
          'type': 'pasteResult',
          'id': request[1] + 1,
          'ok': true,
          'message': '',
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(active.pasteInProgress, true);
        worker.events.send({
          'type': 'pasteResult',
          'id': request[1],
          'ok': true,
          'message': '',
        });
        expect(await paste, true);
        expect(await File(paths.single).parent.parent.exists(), false);
        expect(active.pasteInProgress, false);
      } finally {
        await active.close();
        active.dispose();
      }
    },
  );
  test(
    'close during preparation cancels without a late file publication',
    () async {
      final worker = FileWorker();
      final target = session(worker);
      try {
        await target.connect(password: '');
        await until(() => target.fileClipboardSupported);
        final paste = target.pasteFiles([source()]);
        await target.close();
        expect(await paste, false);
        expect(worker.commands.where((c) => c.first == 'pasteFiles'), isEmpty);
      } finally {
        target.dispose();
      }
    },
  );
  test(
    'old adapter capability and invalid selections fail without worker file calls',
    () async {
      for (final features in [17, 33]) {
        final worker = FileWorker(features: features);
        final active = session(worker);
        try {
          await active.connect(password: '');
          await until(() => active.features == features);
          expect(
            await active.pasteFiles(
              features == 17 ? [XFile('/missing')] : [source(), source()],
            ),
            false,
          );
          expect(
            worker.commands.where((c) => c.first == 'pasteFiles'),
            isEmpty,
          );
          expect(active.pasteInProgress, false);
          expect(active.pasteError, isNotEmpty);
        } finally {
          await active.close();
          active.dispose();
        }
      }
    },
  );
}
