import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/native_video.dart';
import 'package:lrdp/rdp/rdp_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(NativeVideo.channel, null));

  testWidgets(
    'native renderer accepts texture zero, visibility and disposal ignore late status',
    (tester) async {
      final calls = <String>[];
      final changed = <(int, int, int)>[];
      var metadata = <String, dynamic>{
        'id': 0,
        'width': 0,
        'height': 0,
        'uploads': 0,
        'generation': 0,
        'failed': false,
      };
      Completer<Map<String, dynamic>>? pending;
      messenger.setMockMethodCallHandler(NativeVideo.channel, (call) async {
        calls.add(call.method);
        if (call.method == 'create') return metadata;
        if (call.method == 'status') return pending?.future ?? metadata;
        return null;
      });
      var failures = 0;
      final video = (await NativeVideo.create(
        123,
        changed: (video) =>
            changed.add((video.width, video.height, video.uploads)),
        failed: (_) => failures++,
      ))!;
      expect(video.id, 0);
      metadata = {
        ...metadata,
        'width': 1280,
        'height': 800,
        'uploads': 2,
        'generation': 4,
      };
      await video.poll();
      expect(changed.last, (1280, 800, 2));
      await video.setVisible(false);
      final count = calls.where((call) => call == 'status').length;
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls.where((call) => call == 'status').length, count);
      metadata = {
        ...metadata,
        'width': 1920,
        'height': 1080,
        'uploads': 3,
        'generation': 5,
      };
      await video.setVisible(true);
      expect(changed.last, (1920, 1080, 3));
      pending = Completer<Map<String, dynamic>>();
      final polling = video.poll();
      await tester.pump();
      await video.dispose();
      final changes = changed.length;
      pending.complete({...metadata, 'width': 1, 'height': 1, 'uploads': 4});
      await polling;
      await tester.pump(const Duration(milliseconds: 200));
      expect(changed.length, changes);
      expect(failures, 0);
      expect(calls.where((call) => call == 'dispose').length, 1);
    },
  );

  testWidgets('missing native backend and GPU failure permit CPU fallback', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      NativeVideo.channel,
      (call) async => throw MissingPluginException(),
    );
    expect(
      await NativeVideo.create(1, changed: (_) {}, failed: (_) {}),
      isNull,
    );
    messenger.setMockMethodCallHandler(NativeVideo.channel, (call) async {
      if (call.method == 'create') {
        return {
          'id': 88,
          'width': 4,
          'height': 2,
          'uploads': 0,
          'generation': 1,
          'failed': false,
        };
      }
      if (call.method == 'status') return {'failed': true};
      return null;
    });
    var failures = 0;
    final video = (await NativeVideo.create(
      1,
      changed: (_) {},
      failed: (video) {
        failures++;
        unawaited(video.dispose());
      },
    ))!;
    await video.poll();
    await tester.pump(const Duration(milliseconds: 200));
    expect(failures, 1);
  });

  testWidgets(
    'late texture registration after session close releases its reader',
    (tester) async {
      await tester.runAsync(() async {
        final registration = Completer<Map<String, dynamic>>();
        final creating = Completer<void>();
        final disposed = Completer<void>();
        messenger.setMockMethodCallHandler(NativeVideo.channel, (call) async {
          if (call.method == 'create') {
            creating.complete();
            return registration.future;
          }
          if (call.method == 'dispose') disposed.complete();
          return null;
        });
        final commands = <List>[];
        final session = RdpSession(
          const ConnectionProfile(id: 'video', name: 'Test', host: '192.0.2.1'),
          workerLauncher: (init) async {
            final events = init['events'] as SendPort;
            final port = ReceivePort();
            port.listen((dynamic command) {
              if (command is List) {
                commands.add(command);
                if (command.first == 'stop') {
                  events.send({'type': 'done'});
                  port.close();
                }
              }
            });
            events.send(port.sendPort);
            events.send({
              'type': 'state',
              'state': 2,
              'reason': 0,
              'error': '',
              'fingerprint': '',
              'version': 'test',
            });
            events.send({'type': 'video', 'ticket': 123});
          },
        );
        await session.connect(password: '');
        await creating.future;
        await session.close();
        registration.complete({
          'id': 99,
          'width': 1,
          'height': 1,
          'uploads': 0,
          'generation': 1,
          'failed': false,
        });
        await disposed.future;
        expect(session.state, SessionState.closed);
        expect(session.textureId, isNull);
        expect(commands.where((command) => command.first == 'video'), isEmpty);
        session.dispose();
      });
    },
  );
}
