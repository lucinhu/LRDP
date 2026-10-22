import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

      Future<void> modifier(String label) async {
        await tester.tap(find.byKey(Key('remoteModifier$label')));
        await tester.pump();
      }

      // The default mode consumes pending modifiers only for the next key.
      await modifier('Ctrl');
      edit(' ');
      edit(' a');
      await modifier('Shift');
      edit('Ab');
      await modifier('Ctrl');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.tap(find.byKey(const Key('remoteModifierLock')));
      await tester.pump();

      edit('a', composing: true);
      edit('a'); // IME commit must not duplicate the already delivered letter.
      edit('aA1!');
      edit('aA1');
      await tester.testTextInput.receiveAction(TextInputAction.done);
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
      await tester.tap(find.byKey(const Key('remoteNumberKeys')));
      await tester.pumpAndSettle();
      for (final label in ['1', '!']) {
        final key = find.byKey(Key('remoteKey$label'));
        await tester.scrollUntilVisible(key, 250, scrollable: scroll);
        await Scrollable.ensureVisible(tester.element(key), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(key);
        await tester.pump();
      }
      // Exercise both actual IME editing updates and Android-style key events.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      for (final arrow in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await tester.sendKeyEvent(arrow);
      }
      expect(tester.testTextInput.isVisible, isTrue);
      await modifier('Ctrl');
      await modifier('Shift');
      await tester.tap(find.byKey(const Key('remoteModifierLock')));
      await tester.pump();
      edit('c');
      await tester.tap(find.byKey(const Key('remoteModifierLock')));
      await tester.pump();
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
