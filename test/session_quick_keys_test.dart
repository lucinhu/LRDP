import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/floating_controls.dart';
import 'package:lrdp/ui/remote_view.dart';
import 'package:lrdp/ui/theme.dart';

import 'remote_view_test.dart' show RecordingSession;

void main() {
  Future<RecordingSession> mount(
    WidgetTester tester, {
    required TargetPlatform platform,
    required Size size,
    bool connected = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = RecordingSession();
    if (!connected) session.state = SessionState.closed;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light).copyWith(platform: platform),
        home: Scaffold(
          body: RemoteView(
            session: session,
            active: true,
            reconnect: () {},
            disconnect: () {},
            toggleFullscreen: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    session.inputs.clear();
    return session;
  }

  final quickWin = find.descendant(
    of: find.byType(FloatingControls),
    matching: find.widgetWithText(TextButton, 'Win'),
  );

  for (final (label, platform, size) in [
    ('phone', TargetPlatform.android, const Size(410, 850)),
    ('desktop', TargetPlatform.linux, const Size(1280, 800)),
  ]) {
    testWidgets('$label quick Win sends one extended press and release', (
      tester,
    ) async {
      final session = await mount(tester, platform: platform, size: size);
      expect(quickWin.hitTestable(), findsOneWidget);
      expect(tester.widget<TextButton>(quickWin).onPressed, isNotNull);

      await tester.tap(quickWin);
      await tester.pumpAndSettle();

      expect(session.inputs, [(1, 0x0100, 0x5b, 0), (1, 0x8100, 0x5b, 0)]);
      expect(find.byKey(const Key('remoteModifierWin')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label quick Win is disabled without a connection', (
      tester,
    ) async {
      final session = await mount(
        tester,
        platform: platform,
        size: size,
        connected: false,
      );
      expect(quickWin.hitTestable(), findsOneWidget);
      expect(tester.widget<TextButton>(quickWin).onPressed, isNull);

      await tester.tap(quickWin);
      await tester.pumpAndSettle();

      expect(session.inputs, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$label screen keyboard Win still toggles a held modifier', (
      tester,
    ) async {
      final session = await mount(tester, platform: platform, size: size);
      await tester.tap(find.text('键盘'));
      await tester.pumpAndSettle();
      final modifier = find.byKey(const Key('remoteModifierWin'));
      await tester.ensureVisible(modifier);
      await tester.pumpAndSettle();
      session.inputs.clear();

      await tester.tap(modifier);
      await tester.pumpAndSettle();
      expect(session.inputs.where((event) => event.$1 == 1), [
        (1, 0x0100, 0x5b, 0),
      ]);

      await tester.tap(modifier);
      await tester.pumpAndSettle();
      expect(session.inputs.where((event) => event.$1 == 1), [
        (1, 0x0100, 0x5b, 0),
        (1, 0x8100, 0x5b, 0),
      ]);
      expect(tester.takeException(), isNull);
    });
  }
}
