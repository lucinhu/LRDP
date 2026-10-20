import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/image_clipboard.dart';
import 'package:lrdp/ui/remote_view.dart';

void main() {
  testWidgets('image UI and worker exchange exact pixels over private TLS', (
    tester,
  ) async {
    final mode = Platform.environment['LRDP_IMAGE_MODE']!;
    final folder = Directory.systemTemp.createTempSync('lrdp-image-worker-');
    final session = RdpSession(
      ConnectionProfile(
        id: 'image-tls',
        name: 'Private image',
        host: '127.0.0.1',
        port: int.parse(Platform.environment['LRDP_TEST_PORT']!),
        nla: false,
      ),
      protocolDirectory: folder.path,
    );
    final png = File(Platform.environment['LRDP_TEST_PNG']!).readAsBytesSync();
    final dib = File(Platform.environment['LRDP_TEST_DIB']!).readAsBytesSync();
    var reads = 0, writes = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(ImageClipboard.channel, (call) async {
      if (call.method == 'read') {
        reads++;
        return {'kind': 1, 'bytes': png};
      }
      final args = call.arguments as Map;
      expect(args['width'], 3);
      expect(args['height'], 2);
      expect(args['dib'], dib);
      expect(args['rgba'], [
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        255,
        0,
        0,
        255,
        255,
        255,
        255,
        255,
        255,
        0,
        0,
        0,
        255,
        0,
        255,
        255,
        255,
      ]);
      writes++;
      return null;
    });
    Future<void> until(bool Function() predicate, String label) async {
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (!predicate() && DateTime.now().isBefore(end)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        predicate(),
        true,
        reason:
            '$label ${session.state} ${session.error} ${session.pasteError}',
      );
    }

    Future<void> transitions() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    try {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(
        () => session.connect(
          password: '',
          acceptedFingerprint: Platform.environment['LRDP_TEST_PIN']!,
        ),
      );
      await until(
        () =>
            session.state == SessionState.connected &&
            session.imageClipboardSupported,
        'image channel ready',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteView(
              session: session,
              active: true,
              reconnect: () {},
              disconnect: () {},
              toggleFullscreen: () {},
            ),
          ),
        ),
      );
      await transitions();
      if (mode == 'image_dib') {
        await tester.tap(find.text('更多'));
        await transitions();
        await tester.ensureVisible(find.text('粘贴本机图片'));
        await tester.tap(find.text('粘贴本机图片'));
        await transitions();
        await until(
          () =>
              reads == 1 &&
              !session.pasteInProgress &&
              find.textContaining('图片已传输').evaluate().isNotEmpty,
          'image paste confirmation',
        );
        expect(session.pasteError, isEmpty);
        expect(writes, 0);
      } else {
        await until(() => writes == 1, 'remote pixels written to OS clipboard');
        expect(session.remotePicture, isNull);
        expect(reads, 0);
        await tester.pump(const Duration(seconds: 1));
        expect(writes, 1);
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.close);
      session.dispose();
      messenger.setMockMethodCallHandler(ImageClipboard.channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      folder.deleteSync(recursive: true);
    }
  }, skip: Platform.environment['LRDP_IMAGE_MODE'] == null);
}
