import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/remote_input_mode.dart';
import 'package:lrdp/ui/mobile_keyboard.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/remote_view.dart';
import 'package:lrdp/ui/remote_view_memory.dart';
import 'mobile_keyboard_test.dart' show PasteSession;
import 'remote_view_test.dart' show RecordingSession;

Future<void> chooseMode(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('remoteInputMode')));
  await tester.pumpAndSettle();
  final choice = find.widgetWithText(MenuItemButton, label);
  await tester.ensureVisible(choice);
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('desktop full-screen hint stays usable at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final session = RecordingSession();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: Scaffold(
            body: RemoteView(
              session: session,
              active: true,
              fullscreen: true,
              reconnect: () {},
              disconnect: () {},
              toggleFullscreen: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('releaseSessionControl')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('exitSessionFullscreen')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('releaseSessionControl')));
      await tester.pump();
      expect(
        tester.widget<RemoteSurface>(find.byType(RemoteSurface)).inputEnabled,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  }
  testWidgets(
    'IME actions and raw editing keys reach the remote once and keep input active',
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
      expect(find.textContaining('使用英文键盘'), findsNothing);
      final field = find.byKey(
        const Key('remoteTextInput'),
        skipOffstage: false,
      );
      for (final (key, code) in [
        (LogicalKeyboardKey.enter, 0x1c),
        (LogicalKeyboardKey.backspace, 0x0e),
        (LogicalKeyboardKey.arrowLeft, 0x14b),
        (LogicalKeyboardKey.arrowRight, 0x14d),
        (LogicalKeyboardKey.arrowUp, 0x148),
        (LogicalKeyboardKey.arrowDown, 0x150),
      ]) {
        session.scans.clear();
        await tester.sendKeyEvent(key);
        await tester.pump();
        expect(session.scans, [(code, true), (code, false)], reason: '$key');
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
      }
      session.scans.clear();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(session.scans, [(0x1c, true), (0x1c, false)]);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      session.scans.clear();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
      );
      await tester.pump();
      expect(session.scans, [(0x0e, true), (0x0e, false)]);
      session.scans.clear();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200b\n',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      expect(session.scans, [(0x1c, true), (0x1c, false)]);
      await tester.tap(find.byKey(const Key('remoteModifierLock')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('remoteModifierShift')));
      await tester.pump();
      session.scans.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(session.scans, [(0x14b, true), (0x14b, false)]);
      await tester.tap(find.byKey(const Key('remoteModifierLock')));
      await tester.pump();
      expect(session.scans.last, (0x2a, false));
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('remoteInputMode')))
            .focusNode!
            .hasFocus,
        isTrue,
        reason:
            'The simulator must retain keyboard access to the local mode menu',
      );
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  for (final mode in ['文字输入', '粘贴输入']) {
    testWidgets(
      'phone defaults to simulation and retains $mode draft across hiding and remounting',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final memory = RemoteViewMemory();
        final session = RecordingSession();
        final modes = <RemoteInputMode>[];
        Widget view() => MaterialApp(
          home: Scaffold(
            body: RemoteView(
              session: session,
              memory: memory,
              active: true,
              reconnect: () {},
              disconnect: () {},
              toggleFullscreen: () {},
              onInputModeChanged: modes.add,
            ),
          ),
        );
        Future<void> open() async {
          await tester.tap(find.text('键盘'));
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        await open();
        expect(find.byTooltip('输入模式：键盘模拟'), findsOneWidget);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byType(MobileKeyboard), findsNothing);
        expect(
          tester.widget<RemoteSurface>(find.byType(RemoteSurface)).inputEnabled,
          isFalse,
        );
        expect(
          session.inputs.where((e) => e.$1 == 1 && e.$3 == 0x147),
          isEmpty,
        );
        await tester.tap(find.byType(RemoteSurface));
        await tester.pumpAndSettle();
        await open();
        expect(find.byKey(const Key('remoteTextInput')), findsNothing);
        await chooseMode(tester, mode);
        expect(
          modes.last,
          mode == '文字输入' ? RemoteInputMode.text : RemoteInputMode.paste,
        );
        final field = find.byKey(const Key('remoteTextInput'));
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Draft العربية 日本語',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange(start: 0, end: 5),
          ),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('收起键盘'));
        await tester.pumpAndSettle();
        expect(session.texts, isEmpty);
        await open();
        expect(find.byTooltip('输入模式：$mode'), findsOneWidget);
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Draft العربية 日本語',
        );
        expect(
          tester.widget<TextField>(field).controller!.selection.extentOffset,
          5,
        );
        expect(
          tester.widget<TextField>(field).controller!.value.composing,
          TextRange.empty,
        );
        await chooseMode(tester, '键盘模拟');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        await open();
        expect(find.byTooltip('输入模式：键盘模拟'), findsOneWidget);
        await chooseMode(tester, mode);
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Draft العربية 日本語',
        );
        expect(session.texts, isEmpty);
        expect(RemoteViewMemory().textDraft.text, isEmpty);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    testWidgets(
      'modifier lock preference belongs to the open $platform session',
      (tester) async {
        tester.view.physicalSize = platform == TargetPlatform.android
            ? const Size(390, 844)
            : const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final session = RecordingSession();
        var memory = RemoteViewMemory();
        Widget view() => MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: RemoteView(
              session: session,
              memory: memory,
              active: true,
              reconnect: () {},
              disconnect: () {},
              toggleFullscreen: () {},
            ),
          ),
        );
        Future<void> open() async {
          await tester.tap(find.text('键盘'));
          await tester.pumpAndSettle();
        }

        final toggle = find.byKey(const Key('remoteModifierLock'));
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        await open();
        expect(tester.widget<IconButton>(toggle).isSelected, isFalse);
        await tester.tap(toggle);
        await tester.pump();
        expect(memory.modifierLock, isTrue);
        await tester.tap(find.byKey(const Key('remoteExtraKeys')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('remoteNumberKeys')));
        await tester.pumpAndSettle();
        expect(memory.numberKeys, isTrue);
        await tester.tap(find.byKey(const Key('remoteModifierCtrl')));
        await tester.pump();
        await tester.tap(find.byTooltip('收起键盘'));
        await tester.pumpAndSettle();
        expect(
          session.inputs.where(
            (e) => e.$1 == 1 && e.$2 == 0x8000 && e.$3 == 0x1d,
          ),
          hasLength(1),
        );
        await open();
        expect(tester.widget<IconButton>(toggle).isSelected, isTrue);
        expect(find.byKey(const Key('remoteSpecialKeys')), findsNothing);
        await tester.tap(find.byKey(const Key('remoteExtraKeys')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('remoteKey1')).hitTestable(),
          findsOneWidget,
        );
        session.inputs.clear();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '\u200ba',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump();
        expect(
          session.inputs.where((e) => e.$1 == 1 && e.$3 == 0x1d),
          isEmpty,
          reason: 'Restoring the preference must not restore a held key',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        await open();
        expect(tester.widget<IconButton>(toggle).isSelected, isTrue);
        await tester.pumpWidget(const SizedBox());
        memory = RemoteViewMemory();
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        await open();
        expect(tester.widget<IconButton>(toggle).isSelected, isFalse);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }

  testWidgets(
    'desktop full-screen escape releases mouse and keys and resumes without a stray click',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = RecordingSession();
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: Scaffold(
            body: RemoteView(
              session: session,
              active: true,
              fullscreen: true,
              reconnect: () {},
              disconnect: () {},
              toggleFullscreen: () => toggles++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ctrl + Alt + Home'), findsOneWidget);
      final surface = find.byType(RemoteSurface);
      final center = tester.getCenter(surface);
      final mouse = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.home);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(tester.widget<RemoteSurface>(surface).inputEnabled, isFalse);
      expect(
        tester.widget<RemoteSurface>(surface).active,
        isTrue,
        reason: 'Video must remain live',
      );
      expect(
        session.mouseEvents.where((e) => e.$2 & 0x9000 == 0x1000),
        hasLength(1),
      );
      expect(session.inputs.where((e) => e.$1 == 1 && e.$3 == 0x147), isEmpty);
      expect(
        session.inputs.where(
          (e) => e.$1 == 1 && e.$2 == 0x8000 && e.$3 == 0x1d,
        ),
        hasLength(1),
      );
      await mouse.up();
      session.inputs.clear();
      await tester.tapAt(center, kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(
        session.mouseEvents,
        isEmpty,
        reason: 'First click only resumes local capture',
      );
      expect(tester.widget<RemoteSurface>(surface).inputEnabled, isTrue);
      await tester.tapAt(center, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        session.mouseEvents.where((e) => e.$2 & 0x1000 != 0),
        hasLength(2),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(toggles, 1);
      expect(session.inputs.where((e) => e.$1 == 1 && e.$3 == 0x1c), isEmpty);
      await tester.tap(find.byKey(const Key('exitSessionFullscreen')));
      expect(toggles, 2);
      await tester.tap(find.text('键盘'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<RemoteSurface>(surface).inputEnabled, isFalse);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
