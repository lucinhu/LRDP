import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/theme.dart';
import 'package:lrdp/ui/transfer_dialog.dart';

void main() {
  testWidgets('file exchange panel fits phone and desktop with Chinese files', (
    tester,
  ) async {
    late Directory directory;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('lrdp-panel-test-');
      await File('${directory.path}/收到的中文文件.txt').writeAsString('中文内容');
    });
    addTearDown(() => directory.delete(recursive: true));
    final session = RdpSession(
      const ConnectionProfile(
        id: 'files',
        name: 'test',
        host: 'localhost',
        fileTransfer: true,
      ),
    );
    session.transferDirectory = directory.path;
    addTearDown(session.dispose);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final size in [
      const Size(320, 568),
      const Size(844, 390),
      const Size(1000, 800),
    ]) {
      tester.view.physicalSize = size;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: TransferDialog(
                key: ValueKey(size),
                directory: directory.path,
                sharingEnabled: true,
                session: session,
              ),
            ),
          ),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (find.text('收到的中文文件.txt').evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('收到的中文文件.txt'), findsOneWidget);
      expect(find.text(r'\\tsclient\LRDP'), findsOneWidget);
    }
  });
}
