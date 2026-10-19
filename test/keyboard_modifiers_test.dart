import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/ui/mobile_keyboard.dart';
import 'mobile_keyboard_test.dart' show PasteSession;

void main() {
  Future<void> mount(WidgetTester tester, PasteSession session) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MobileKeyboard(
              session: session,
              close: () {},
              shortcuts: false,
              simulateKeys: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> modifier(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(Key('remoteModifier$label')));
    await tester.pump();
  }

  void edit(WidgetTester tester, String text) {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '\u200b$text',
        selection: TextSelection.collapsed(offset: text.length + 1),
      ),
    );
  }

  testWidgets(
    'latched Ctrl combines with IME space and letters until explicitly released',
    (tester) async {
      final session = PasteSession();
      await mount(tester, session);
      await modifier(tester, 'Ctrl');
      edit(tester, ' ');
      edit(tester, ' a');
      expect(session.scans, [
        (0x1d, true),
        (0x39, true),
        (0x39, false),
        (0x1e, true),
        (0x1e, false),
      ]);
      expect(tester.testTextInput.isVisible, isTrue);
      await modifier(tester, 'Ctrl');
      expect(session.scans.last, (0x1d, false));
      await tester.pumpWidget(const SizedBox());
      expect(session.scans.where((e) => e == (0x1d, false)).length, 1);
      session.dispose();
    },
  );
  testWidgets(
    'latched Shift survives an uppercase IME chord and subsequent typing',
    (tester) async {
      final session = PasteSession();
      await mount(tester, session);
      await modifier(tester, 'Shift');
      edit(tester, 'A');
      edit(tester, 'Ab');
      expect(session.scans, [
        (0x2a, true),
        (0x1e, true),
        (0x1e, false),
        (0x30, true),
        (0x30, false),
      ]);
      expect(
        find.ancestor(
          of: find.byKey(const Key('remoteModifierShift')),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.toggled == true,
          ),
        ),
        findsOneWidget,
      );
      await modifier(tester, 'Shift');
      expect(session.scans.last, (0x2a, false));
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'all function keys and Ctrl Alt Delete preserve latched modifiers',
    (tester) async {
      final session = PasteSession();
      await mount(tester, session);
      await modifier(tester, 'Ctrl');
      await modifier(tester, 'Alt');
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
      final delete = find.byKey(const Key('remoteKeyCtrl+Alt+Del'));
      await tester.scrollUntilVisible(delete, 250, scrollable: scroll);
      await tester.tap(delete);
      await tester.pump();
      expect(session.scans.take(2), [(0x1d, true), (0x38, true)]);
      expect(session.scans.sublist(2), [
        for (final code in [
          for (var i = 1; i <= 10; i++) 0x3a + i,
          0x57,
          0x58,
          0x153,
        ]) ...[(code, true), (code, false)],
      ]);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(session.scans.sublist(session.scans.length - 2), [
        (0x38, false),
        (0x1d, false),
      ]);
      session.dispose();
    },
  );
  for (final action in ['close', 'background', 'focus']) {
    testWidgets('$action releases held keys exactly once', (tester) async {
      final session = PasteSession();
      await mount(tester, session);
      await modifier(tester, 'Ctrl');
      await modifier(tester, 'Shift');
      if (action == 'close') {
        await tester.pumpWidget(const SizedBox());
      } else if (action == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
      } else {
        tester
            .widget<TextField>(
              find.byKey(const Key('remoteTextInput'), skipOffstage: false),
            )
            .focusNode!
            .unfocus();
        await tester.pumpAndSettle();
      }
      expect(session.scans, [
        (0x1d, true),
        (0x2a, true),
        (0x2a, false),
        (0x1d, false),
      ]);
      await tester.pumpWidget(const SizedBox());
      expect(session.scans.length, 4);
      session.dispose();
    });
  }
  testWidgets(
    'switching to text input releases held modifiers before Unicode send',
    (tester) async {
      final session = PasteSession();
      await mount(tester, session);
      await modifier(tester, 'Ctrl');
      await tester.tap(find.byKey(const Key('remoteInputMode')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, '文字输入'));
      await tester.pumpAndSettle();
      expect(session.scans, [(0x1d, true), (0x1d, false)]);
      await tester.enterText(find.byKey(const Key('remoteTextInput')), '中文');
      await tester.pump();
      await tester.tap(find.byKey(const Key('pasteRemoteText')));
      await tester.pump();
      expect(session.unicode, ['中文']);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
