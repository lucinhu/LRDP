import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/keyboard_keys.dart';
import 'package:lrdp/ui/remote_keyboard.dart';

import 'remote_keyboard_test.dart' show PasteSession;

void main() {
  Future<PasteSession> mount(
    WidgetTester tester, {
    bool shortcuts = true,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = PasteSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemoteKeyboard(
            session: session,
            close: () {},
            shortcuts: shortcuts,
            simulateKeys: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return session;
  }

  Finder scrollable() => find.descendant(
    of: find.byKey(const Key('remoteSpecialKeys')),
    matching: find.byType(Scrollable),
  );

  Future<void> reveal(WidgetTester tester, Finder key) async {
    await tester.scrollUntilVisible(key, 200, scrollable: scrollable());
    await tester.pumpAndSettle();
  }

  testWidgets('a single tap still sends exactly one chord', (tester) async {
    final session = await mount(tester);
    final key = find.byKey(const Key('remoteKey→'));
    await reveal(tester, key);
    await tester.tap(key);
    await tester.pump();
    expect(session.scans, [(0x14d, true), (0x14d, false)]);
  });

  testWidgets('holding an arrow key repeats it until the pointer is released', (
    tester,
  ) async {
    final session = await mount(tester);
    final key = find.byKey(const Key('remoteKey→'));
    await reveal(tester, key);
    final gesture = await tester.startGesture(tester.getCenter(key));
    await tester.pump();
    expect(
      session.scans,
      isEmpty,
      reason: 'A press must not fire before long press wins the arena',
    );
    await tester.pump(keyRepeatStart + const Duration(milliseconds: 20));
    expect(session.scans, [(0x14d, true), (0x14d, false)]);
    session.scans.clear();
    await tester.pump(keyRepeatInterval * 3);
    expect(session.scans, [
      for (var i = 0; i < 3; i++) ...[(0x14d, true), (0x14d, false)],
    ]);
    await gesture.up();
    await tester.pump();
    session.scans.clear();
    await tester.pump(keyRepeatInterval * 4);
    expect(
      session.scans,
      isEmpty,
      reason: 'Auto-repeat must stop when the key is released',
    );
  });

  testWidgets('a long hold on a non-repeatable key sends it once', (
    tester,
  ) async {
    final session = await mount(tester);
    final key = find.byKey(const Key('remoteKeyEsc'));
    await reveal(tester, key);
    final gesture = await tester.startGesture(tester.getCenter(key));
    await tester.pump(keyRepeatStart + const Duration(milliseconds: 200));
    expect(session.scans, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(session.scans, [(0x01, true), (0x01, false)]);
  });

  testWidgets(
    'holding backspace deletes continuously without sending letters',
    (tester) async {
      final session = await mount(tester);
      await tester.tap(find.text('显示键盘'));
      await tester.pumpAndSettle();
      final backspace = find.byKey(const Key('remoteBackspace'));
      final gesture = await tester.startGesture(tester.getCenter(backspace));
      await tester.pump(keyRepeatStart + const Duration(milliseconds: 20));
      expect(session.scans, [(0x0e, true), (0x0e, false)]);
      session.scans.clear();
      await tester.pump(keyRepeatInterval * 4);
      expect(session.scans, [
        for (var i = 0; i < 4; i++) ...[(0x0e, true), (0x0e, false)],
      ]);
      await gesture.up();
      await tester.pump();
    },
  );

  testWidgets('scrolling the key bar never types into the session', (
    tester,
  ) async {
    final session = await mount(tester);
    expect(find.byKey(const Key('remoteSpecialKeys')), findsOneWidget);
    await tester.drag(scrollable(), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(
      session.scans,
      isEmpty,
      reason: 'Dragging across key buttons must scroll instead of pressing',
    );
  });

  for (final lifecycle in [
    AppLifecycleState.inactive,
    AppLifecycleState.paused,
  ]) {
    testWidgets('auto-repeat stops on $lifecycle and never resumes itself', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final session = await mount(tester);
      final key = find.byKey(const Key('remoteKey→'));
      await reveal(tester, key);
      final gesture = await tester.startGesture(tester.getCenter(key));
      await tester.pump(keyRepeatStart + const Duration(milliseconds: 20));
      expect(session.scans, hasLength(2));
      if (lifecycle == AppLifecycleState.paused) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      }
      tester.binding.handleAppLifecycleStateChanged(lifecycle);
      session.scans.clear();
      await tester.pump(keyRepeatInterval * 4);
      expect(session.scans, isEmpty);
      if (lifecycle == AppLifecycleState.paused) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(keyRepeatInterval * 4);
      expect(
        session.scans,
        isEmpty,
        reason: 'Returning to the app must require a new press',
      );
      await gesture.up();
      await tester.pump();
    });
  }

  testWidgets('even a brief focus loss cancels an existing repeat timer', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final session = await mount(tester);
    final key = find.byKey(const Key('remoteKey→'));
    await reveal(tester, key);
    final gesture = await tester.startGesture(tester.getCenter(key));
    await tester.pump(keyRepeatStart + const Duration(milliseconds: 20));
    expect(session.scans, hasLength(2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    session.scans.clear();
    await tester.pump(keyRepeatInterval * 4);
    expect(session.scans, isEmpty);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('auto-repeat stops once the session is no longer connected', (
    tester,
  ) async {
    final session = await mount(tester);
    final key = find.byKey(const Key('remoteKey→'));
    await reveal(tester, key);
    final gesture = await tester.startGesture(tester.getCenter(key));
    await tester.pump(keyRepeatStart + const Duration(milliseconds: 20));
    expect(session.scans, hasLength(2));
    session.state = SessionState.closed;
    session.scans.clear();
    await tester.pump(keyRepeatInterval * 4);
    expect(session.scans, isEmpty);
    await gesture.up();
    await tester.pump();
  });
}
