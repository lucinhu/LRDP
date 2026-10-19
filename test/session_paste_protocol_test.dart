import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/mobile_keyboard.dart';
import 'package:lrdp/ui/theme.dart';

void main() {
  testWidgets(
    'real clipboard paste confirms delivery or preserves text on cancellation',
    (tester) async {
      final mode = Platform.environment['LRDP_PASTE_MODE']!;
      final direct = mode.startsWith('unicode');
      final unsupported = mode == 'unicode_unsupported';
      final directory = Directory.systemTemp.createTempSync(
        'lrdp-paste-flutter-',
      );
      final session = RdpSession(
        ConnectionProfile(
          id: 'paste-protocol',
          name: 'Private paste',
          host: '127.0.0.1',
          port: int.parse(Platform.environment['LRDP_TEST_PORT']!),
          nla: false,
        ),
        protocolDirectory: directory.path,
      );
      Future<void> until(bool Function() predicate, String label) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!predicate() && DateTime.now().isBefore(deadline)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
        }
        expect(
          predicate(),
          isTrue,
          reason:
              '$label: ${session.state} ${session.pasteError} ${session.error}',
        );
      }

      try {
        await tester.runAsync(
          () => session.connect(
            password: '',
            acceptedFingerprint: Platform.environment['LRDP_TEST_PIN']!,
          ),
        );
        await until(
          () =>
              session.state == SessionState.connected &&
              session.clipboardSupported,
          'TLS and clipboard readiness',
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: MobileKeyboard(
                  session: session,
                  pasteText: !direct,
                  close: () {},
                  shortcuts: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final input = find.byKey(const Key('remoteTextInput'));
        final text = direct ? 'LRDP 中文输入验证 你好 😀' : 'LRDP 中文输入验证 你好';
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
            composing: TextRange(start: 0, end: text.length),
          ),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('pasteRemoteText')));
        await tester.pump();
        expect(session.pasteInProgress, !direct);
        if (unsupported) {
          expect(session.unicodeInputSupported, isFalse);
          expect(tester.widget<TextField>(input).controller!.text, text);
          expect(find.textContaining('远端不支持直接文字输入'), findsOneWidget);
          expect(session.state, SessionState.connected);
          return;
        }
        if (direct) {
          expect(session.unicodeInputSupported, isTrue);
          expect(tester.widget<TextField>(input).controller!.text, isEmpty);
          expect(session.state, SessionState.connected);
          // Allow the isolated worker to flush every UTF-16 down/up pair;
          // the independent TLS peer validates the actual bytes on close.
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 700)),
          );
          return;
        }
        if (Platform.environment['LRDP_PASTE_MODE'] == 'cancel') {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.runAsync(session.close);
          await tester.pump();
          expect(tester.widget<TextField>(input).controller!.text, text);
          expect(session.pasteError, contains('文字未确认发送'));
        } else {
          await until(
            () => !session.pasteInProgress,
            'Acknowledgement, Ctrl+V and UTF-16 transfer',
          );
          expect(session.pasteError, isEmpty);
          expect(tester.widget<TextField>(input).controller!.text, isEmpty);
          expect(session.state, SessionState.connected);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(session.close);
        await tester.pump();
        session.dispose();
        directory.deleteSync(recursive: true);
      }
    },
    skip: Platform.environment['LRDP_PASTE_MODE'] == null,
  );
}
