import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/mobile_keyboard.dart';
import 'package:lrdp/ui/theme.dart';

class PasteSession extends RdpSession {
  PasteSession()
    : super(
        const ConnectionProfile(id: 'paste', name: 'Test', host: '192.0.2.1'),
      ) {
    state = SessionState.connected;
    features = 9;
  }
  final sent = <String>[];
  final completions = <Completer<bool>>[];
  final scans = <(int, bool)>[];
  final unicode = <String>[];
  @override
  void scan(int code, bool down) => scans.add((code, down));
  @override
  void text(String text) => unicode.add(text);
  @override
  Future<bool> paste(String text) {
    sent.add(text);
    final completion = Completer<bool>();
    completions.add(completion);
    return completion.future;
  }
}

void main() {
  testWidgets(
    'show keyboard restores the input client before showing the IME',
    (tester) async {
      final session = PasteSession();
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
      final field = find.byKey(
        const Key('remoteTextInput'),
        skipOffstage: false,
      );
      tester.testTextInput.closeConnection();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      tester.testTextInput.log.clear();
      await tester.tap(find.text('显示键盘'));
      await tester.pumpAndSettle();
      final calls = tester.testTextInput.log
          .map((call) => call.method)
          .toList();
      final attach = calls.indexOf('TextInput.setClient');
      final show = calls.indexOf('TextInput.show');
      expect(attach, greaterThanOrEqualTo(0));
      expect(
        show,
        greaterThan(attach),
        reason: 'Never show an IME without a client',
      );
      expect(tester.testTextInput.isVisible, isTrue);
      expect(find.byType(EditableText), findsNothing);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200ba',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      expect(session.scans, [(0x1e, true), (0x1e, false)]);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('input modes stay above the IME at 200% on $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final session = PasteSession();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MobileKeyboard(
                session: session,
                close: () {},
                shortcuts: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remoteInputMode')));
      await tester.pumpAndSettle();
      for (final label in ['文字输入', '键盘模拟']) {
        final choice = find.text(label).last;
        expect(
          tester.getRect(choice).bottom,
          lessThanOrEqualTo(size.height - 160),
          reason: 'The system IME must not cover a mode choice',
        );
      }
      await tester.tap(find.text('键盘模拟').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('输入模式：键盘模拟'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('remoteTextInput'), skipOffstage: false),
            )
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  }
  testWidgets(
    'IME keyboard mode sends composing Latin keys once and handles deletion and Enter',
    (tester) async {
      final session = PasteSession();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MobileKeyboard(
              session: session,
              close: () {},
              shortcuts: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(
        const Key('remoteTextInput'),
        skipOffstage: false,
      );
      await tester.enterText(field, '保留草稿');
      await tester.tap(find.byKey(const Key('remoteInputMode')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).focusNode!.hasFocus,
        isTrue,
        reason: 'Choosing an input mode must keep the IME open',
      );
      await tester.tap(find.text('键盘模拟'));
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
      edit('ab', composing: true);
      edit('ab');
      expect(session.scans, [
        (0x1e, true),
        (0x1e, false),
        (0x30, true),
        (0x30, false),
      ]);
      edit('a');
      expect(session.scans.sublist(4), [(0x0e, true), (0x0e, false)]);
      edit('');
      tester.testTextInput.updateEditingValue(TextEditingValue.empty);
      expect(
        session.scans.where((e) => e == (0x0e, true)).length,
        3,
        reason: 'Backspace also works with an empty local input',
      );
      session.scans.clear();
      edit('A!');
      expect(session.scans, [
        (0x2a, true),
        (0x1e, true),
        (0x1e, false),
        (0x2a, false),
        (0x2a, true),
        (0x02, true),
        (0x02, false),
        (0x2a, false),
      ]);
      final before = session.scans.toList();
      edit('中文');
      await tester.pump();
      expect(
        session.scans,
        before,
        reason: 'Reject unsupported replacement before deleting remote text',
      );
      expect(session.unicode, isEmpty);
      expect(find.textContaining('此内容无法模拟为按键'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(session.scans.sublist(before.length), [
        (0x1c, true),
        (0x1c, false),
      ]);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await tester.tap(find.byKey(const Key('remoteInputMode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文字输入'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '保留草稿');
      // A physical keyboard can still focus, navigate and select the menu.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final choice = find.text('键盘模拟');
      expect(choice, findsOneWidget);
      for (
        var i = 0;
        i < 3 && !Focus.of(tester.element(choice)).hasFocus;
        i++
      ) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(Focus.of(tester.element(choice)).hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byTooltip('输入模式：键盘模拟'), findsOneWidget);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'unsupported direct input retains Chinese instead of sending or disconnecting',
    (tester) async {
      final session = PasteSession()..features = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MobileKeyboard(
              session: session,
              close: () {},
              shortcuts: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('remoteTextInput'));
      await tester.enterText(field, '保留中文');
      await tester.pump();
      await tester.tap(find.byKey(const Key('pasteRemoteText')));
      await tester.pumpAndSettle();
      expect(session.unicode, isEmpty);
      expect(session.sent, isEmpty);
      expect(tester.widget<TextField>(field).controller!.text, '保留中文');
      expect(find.textContaining('远端不支持直接文字输入'), findsOneWidget);
      expect(session.state, SessionState.connected);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  for (final clipboard in [false, true]) {
    testWidgets(
      'Chinese send uses Unicode independently of clipboard ($clipboard)',
      (tester) async {
        final session = PasteSession()..features = clipboard ? 9 : 8;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MobileKeyboard(
                session: session,
                close: () {},
                shortcuts: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        const text = '中文输入 你好 😀';
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
            composing: TextRange(start: 0, end: text.length),
          ),
        );
        await tester.pump();
        expect(session.unicode, isEmpty);
        await tester.tap(find.byKey(const Key('pasteRemoteText')));
        await tester.pumpAndSettle();
        expect(session.unicode, [text]);
        expect(session.sent, isEmpty);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('remoteTextInput')))
              .controller!
              .text,
          isEmpty,
        );
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }
  testWidgets(
    'switching direct and paste input preserves the Chinese draft and focus',
    (tester) async {
      final session = PasteSession();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MobileKeyboard(
              session: session,
              close: () {},
              shortcuts: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('remoteTextInput'));
      await tester.enterText(field, '保留中文草稿');
      for (final label in ['粘贴输入', '文字输入']) {
        await tester.tap(find.byKey(const Key('remoteInputMode')));
        await tester.pumpAndSettle();
        final choice = find.widgetWithText(MenuItemButton, label);
        await tester.ensureVisible(choice);
        await tester.tap(choice);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, '保留中文草稿');
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(find.byTooltip('输入模式：$label'), findsOneWidget);
      }
      expect(session.unicode, isEmpty);
      expect(session.sent, isEmpty);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'paste keeps text until confirmation, retains failures and newer edits at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final session = PasteSession();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: const Size(320, 300),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: MobileKeyboard(
                    pasteText: true,
                    session: session,
                    close: () {},
                    shortcuts: false,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final text = find.byKey(
          const Key('remoteTextInput'),
          skipOffstage: false,
        );
        final paste = find.byKey(const Key('pasteRemoteText'));
        String current() => tester.widget<TextField>(text).controller!.text;
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '中文输入',
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange(start: 0, end: 4),
          ),
        );
        await tester.pump();
        await tester.tap(paste);
        await tester.pump();
        expect(session.sent, ['中文输入']);
        expect(
          session.unicode,
          isEmpty,
          reason: 'Explicit paste mode must use the clipboard',
        );
        expect(current(), '中文输入');
        expect(tester.widget<IconButton>(paste).onPressed, isNull);
        session.completions.last.complete(true);
        await tester.pumpAndSettle();
        expect(current(), isEmpty);

        await tester.enterText(text, '失败后保留');
        await tester.pump();
        await tester.tap(paste);
        await tester.pump();
        session.pasteError = '远程端未接受粘贴，文字已保留';
        session.completions.last.complete(false);
        await tester.pumpAndSettle();
        expect(current(), '失败后保留');
        expect(find.text(session.pasteError), findsOneWidget);
        expect(paste.hitTestable(), findsOneWidget);
        expect(tester.getSize(paste).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);

        await tester.tap(paste);
        await tester.pump();
        await tester.enterText(text, '发送期间的新文字');
        session.completions.last.complete(true);
        await tester.pumpAndSettle();
        expect(current(), '发送期间的新文字');
        await tester.tap(find.byKey(const Key('remoteInputMode')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('键盘模拟'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('回车').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }
}
