import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/mobile_keyboard.dart';

void main() {
  testWidgets('IME edits reach real RDP as Latin scan codes', (tester) async {
    final session = RdpSession(
      ConnectionProfile(
        id: 'keyboard-wire',
        name: 'Private keyboard',
        host: '127.0.0.1',
        port: int.parse(Platform.environment['LRDP_KEYBOARD_PORT']!),
        nla: false,
        clipboard: false,
      ),
      protocolDirectory: Platform.environment['LRDP_KEYBOARD_CONFIG'],
    );
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 400 && !ready(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(ready(), isTrue, reason: '${session.state}: ${session.error}');
    }

    try {
      await tester.runAsync(() => session.connect(password: ''));
      await until(() => session.state == SessionState.certificateRequired);
      await tester.runAsync(
        () => session.connect(
          password: '',
          acceptedFingerprint: session.fingerprint,
        ),
      );
      await until(() => session.image != null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MobileKeyboard(
              session: session,
              close: () {},
              shortcuts: false,
              simulateKeys: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      void edit(String text, {bool composing = false}) {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: '\u200b$text',
            selection: TextSelection.collapsed(offset: text.length + 1),
            composing: composing
                ? TextRange(start: 1, end: text.length + 1)
                : TextRange.empty,
          ),
        );
      }

      edit('a', composing: true);
      edit('a'); // IME commit must not duplicate the already delivered letter.
      edit('aA1!');
      edit('aA1');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      Future<void> modifier(String label) async {
        await tester.tap(find.byKey(Key('remoteModifier$label')));
        await tester.pump();
      }

      await modifier('Ctrl');
      edit(' ');
      await modifier('Ctrl');
      await modifier('Shift');
      edit('A');
      edit('Ab');
      await modifier('Shift');
      await tester.tap(find.byKey(const Key('remoteExtraKeys')));
      await tester.pumpAndSettle();
      final scroll = find.descendant(
        of: find.byKey(const Key('remoteSpecialKeys')),
        matching: find.byType(Scrollable),
      );
      for (var i = 1; i <= 12; i++) {
        final key = find.byKey(Key('remoteKeyF$i'));
        await tester.scrollUntilVisible(key, 250, scrollable: scroll);
        await tester.tap(key);
        await tester.pump();
      }
      // Widget disposal must release a still-latched Alt before disconnect.
      await modifier('Alt');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      expect(session.state, SessionState.connected);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.close);
      session.dispose();
    }
  }, skip: Platform.environment['LRDP_KEYBOARD_PORT'] == null);
}
