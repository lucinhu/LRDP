import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/ui/mobile_keyboard.dart';
import 'mobile_keyboard_test.dart' show PasteSession;

void main() {
  Future<void> mount(
    WidgetTester tester,
    PasteSession session, {
    bool locked = false,
    ValueChanged<bool>? onLockChanged,
  }) async {
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
              initialModifierLock: locked,
              onModifierLockChanged: onLockChanged,
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

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'number keys keep IME focus, combine modifiers and reset scrolling at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final session = PasteSession();
        await mount(tester, session);
        expect(find.byKey(const Key('remoteNumberKeys')), findsNothing);
        await tester.tap(find.byKey(const Key('remoteExtraKeys')));
        await tester.pumpAndSettle();
        final scroll = find.descendant(
          of: find.byKey(const Key('remoteSpecialKeys')),
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('remoteKeyF12')),
          250,
          scrollable: scroll,
        );
        await modifier(tester, 'Ctrl');
        await tester.tap(find.byKey(const Key('remoteNumberKeys')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('remoteKey1')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('remoteKey1')));
        await tester.pump();
        expect(session.scans, [
          (0x1d, true),
          (0x02, true),
          (0x02, false),
          (0x1d, false),
        ]);
        session.scans.clear();
        final symbol = find.byKey(const Key('remoteKey!'));
        await tester.scrollUntilVisible(symbol, 250, scrollable: scroll);
        await Scrollable.ensureVisible(tester.element(symbol), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(symbol);
        await tester.pump();
        expect(session.scans, [
          (0x2a, true),
          (0x02, true),
          (0x02, false),
          (0x2a, false),
        ]);
        await tester.tap(find.byKey(const Key('remoteNumberKeys')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('remoteKeyEsc')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }

  testWidgets(
    'modifiers apply once by default, including a batch of IME text',
    (tester) async {
      final session = PasteSession();
      await mount(tester, session);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('remoteModifierLock')))
            .isSelected,
        isFalse,
      );
      await modifier(tester, 'Ctrl');
      edit(tester, ' ');
      edit(tester, ' a');
      expect(session.scans, [
        (0x1d, true),
        (0x39, true),
        (0x39, false),
        (0x1d, false),
        (0x1e, true),
        (0x1e, false),
      ]);
      session.scans.clear();
      await modifier(tester, 'Ctrl');
      await modifier(tester, 'Shift');
      edit(tester, 'Ab');
      await tester.pump();
      expect(session.scans, [
        (0x1d, true),
        (0x2a, true),
        (0x1e, true),
        (0x1e, false),
        (0x2a, false),
        (0x1d, false),
        (0x30, true),
        (0x30, false),
      ]);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(session.scans.length, 8, reason: 'Do not release modifiers twice');
      session.dispose();
    },
  );

  testWidgets(
    'lock switch promotes pending keys and releases them on disable',
    (tester) async {
      final session = PasteSession();
      final changes = <bool>[];
      await mount(tester, session, onLockChanged: changes.add);
      await modifier(tester, 'Shift');
      final toggle = find.byKey(const Key('remoteModifierLock'));
      await tester.tap(toggle);
      await tester.pump();
      expect(changes, [true]);
      expect(tester.widget<IconButton>(toggle).isSelected, isTrue);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      edit(tester, 'Ab');
      expect(session.scans, [
        (0x2a, true),
        (0x1e, true),
        (0x1e, false),
        (0x30, true),
        (0x30, false),
      ]);
      await tester.tap(toggle);
      await tester.pump();
      expect(changes, [true, false]);
      expect(session.scans.last, (0x2a, false));
      expect(tester.widget<IconButton>(toggle).isSelected, isFalse);
      edit(tester, 'Abc');
      expect(session.scans.sublist(6), [(0x2e, true), (0x2e, false)]);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(toggle);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();
      expect(
        session.scans.length,
        8,
        reason: 'An idle switch sends no remote key',
      );
      expect(changes, [true, false, true, false]);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'raw editing keys and toolbar shortcuts consume pending modifiers',
    (tester) async {
      final session = PasteSession();
      await mount(tester, session);
      await modifier(tester, 'Ctrl');
      await modifier(tester, 'Shift');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(session.scans, [
        (0x1d, true),
        (0x2a, true),
        (0x14b, true),
        (0x14b, false),
        (0x2a, false),
        (0x1d, false),
        (0x14b, true),
        (0x14b, false),
      ]);
      session.scans.clear();
      await modifier(tester, 'Ctrl');
      await tester.tap(find.byKey(const Key('remoteExtraKeys')));
      await tester.pumpAndSettle();
      final scroll = find.descendant(
        of: find.byKey(const Key('remoteSpecialKeys')),
        matching: find.byType(Scrollable),
      );
      final shortcut = find.byKey(const Key('remoteKeyCtrl+Z'));
      await tester.scrollUntilVisible(shortcut, 250, scrollable: scroll);
      await Scrollable.ensureVisible(tester.element(shortcut), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(shortcut);
      await tester.pump();
      expect(session.scans, [
        (0x1d, true),
        (0x2c, true),
        (0x2c, false),
        (0x1d, false),
      ]);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'latched Ctrl combines with IME space and letters until explicitly released',
    (tester) async {
      final session = PasteSession();
      await mount(tester, session, locked: true);
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
      await mount(tester, session, locked: true);
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
    'editing and function keys preserve latched modifiers in the expanded row',
    (tester) async {
      final session = PasteSession();
      await mount(tester, session, locked: true);
      await modifier(tester, 'Ctrl');
      await modifier(tester, 'Alt');
      await tester.tap(find.byKey(const Key('remoteExtraKeys')));
      await tester.pumpAndSettle();
      final scroll = find.descendant(
        of: find.byKey(const Key('remoteSpecialKeys')),
        matching: find.byType(Scrollable),
      );
      final editing = <String, int>{
        'Home': 0x147,
        'End': 0x14f,
        'PgUp': 0x149,
        'PgDn': 0x151,
        'Insert': 0x152,
        'Delete': 0x153,
        '退格': 0x0e,
        '回车': 0x1c,
        'Ctrl+X': 0x2d,
        'Ctrl+Z': 0x2c,
        'Ctrl+Y': 0x15,
      };
      for (final label in [...editing.keys, 'Ctrl+Alt+Del']) {
        final key = find.byKey(Key('remoteKey$label'));
        await tester.scrollUntilVisible(key, 250, scrollable: scroll);
        await Scrollable.ensureVisible(tester.element(key), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(key);
        await tester.pump();
      }
      for (var i = 1; i <= 12; i++) {
        final key = find.byKey(Key('remoteKeyF$i'));
        await tester.scrollUntilVisible(key, 250, scrollable: scroll);
        await Scrollable.ensureVisible(tester.element(key), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(key);
        await tester.pump();
      }
      expect(session.scans.take(2), [(0x1d, true), (0x38, true)]);
      expect(session.scans.sublist(2), [
        for (final code in [
          ...editing.values,
          0x153,
          for (var i = 1; i <= 10; i++) 0x3a + i,
          0x57,
          0x58,
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
  for (final locked in [false, true]) {
    for (final action in ['close', 'background', 'focus']) {
      testWidgets('$action releases held keys exactly once (lock=$locked)', (
        tester,
      ) async {
        final session = PasteSession();
        await mount(tester, session, locked: locked);
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
