import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/remote_view.dart';

void main() {
  testWidgets('file picker UI, worker and native stream over private TLS', (
    tester,
  ) async {
    final mode = Platform.environment['LRDP_FILE_MODE']!;
    final directory = Directory.systemTemp.createTempSync('lrdp-file-worker-');
    final paths = (jsonDecode(Platform.environment['LRDP_TEST_FILES']!) as List)
        .cast<String>();
    final target = RdpSession(
      ConnectionProfile(
        id: 'files-tls',
        name: 'Private files',
        host: '127.0.0.1',
        port: int.parse(Platform.environment['LRDP_TEST_PORT']!),
        nla: false,
      ),
      protocolDirectory: directory.path,
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    var selections = 0, clipboardReads = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') clipboardReads++;
      return null;
    });
    const picker = MethodChannel('plugins.flutter.io/file_selector');
    messenger.setMockMethodCallHandler(picker, (call) async {
      expect(call.method, 'openFile');
      expect((call.arguments as Map)['multiple'], true);
      selections++;
      return paths;
    });
    Future<void> until(bool Function() predicate, String label) async {
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (!predicate() && DateTime.now().isBefore(end)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        predicate(),
        true,
        reason: '$label ${target.state} ${target.error} ${target.pasteError}',
      );
    }

    Future<void> transitions() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    try {
      tester.view.physicalSize = const Size(410, 850);
      tester.view.devicePixelRatio = 1;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(
        () => target.connect(
          password: '',
          acceptedFingerprint: Platform.environment['LRDP_TEST_PIN']!,
        ),
      );
      await until(
        () =>
            target.state == SessionState.connected &&
            target.imageClipboardSupported,
        'clipboard ready',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: RemoteView(
              session: target,
              active: true,
              reconnect: () {},
              disconnect: () {},
              toggleFullscreen: () {},
            ),
          ),
        ),
      );
      await transitions();
      await tester.tap(find.text('更多'));
      await transitions();
      await tester.ensureVisible(find.text('选择文件粘贴'));
      await tester.pump();
      if (mode == 'unsupported') {
        expect(find.text('文件剪贴板不可用，可检查连接偏好或使用文件中转站'), findsOneWidget);
        final tile = tester.widget<ListTile>(
          find.ancestor(
            of: find.text('选择文件粘贴'),
            matching: find.byType(ListTile),
          ),
        );
        expect(tile.enabled, false);
        expect(target.fileClipboardSupported, false);
        await tester.tap(find.text('选择文件粘贴'));
        await transitions();
        expect(selections, 0);
      } else {
        expect(target.fileClipboardSupported, true);
        await tester.tap(find.text('选择文件粘贴'));
        await transitions();
        await until(
          () =>
              selections == 1 &&
              !target.pasteInProgress &&
              find.textContaining('已发送文件粘贴请求').evaluate().isNotEmpty,
          'paste request confirmation',
        );
        expect(target.pasteError, isEmpty);
        // The independent peer needs all asynchronous channel fragments before teardown.
        await until(
          () => File(Platform.environment['LRDP_TEST_PEER_LOG']!)
              .readAsStringSync()
              .contains('PASS: full files and invalid requests checked'),
          'independent peer received every requested file byte',
        );
      }
      expect(
        clipboardReads,
        0,
        reason: 'Phone file selection never reads unrelated text clipboard',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(target.close);
      target.dispose();
      tester.view.reset();
      messenger.setMockMethodCallHandler(picker, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      directory.deleteSync(recursive: true);
    }
  }, skip: Platform.environment['LRDP_FILE_MODE'] == null);
}
