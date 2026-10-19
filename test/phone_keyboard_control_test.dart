import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/remote_view.dart';
import 'package:lrdp/ui/theme.dart';
import 'remote_view_test.dart' show RecordingSession;

void main() {
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    for (final keys in [false, true]) {
      testWidgets('phone remote gestures keep IME active (keys=$keys, $size)', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final session = RecordingSession();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
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
        await tester.tap(find.text('键盘'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = FakeViewPadding(
          bottom: size.height > 500 ? 280 : 170,
        );
        await tester.pumpAndSettle();
        if (keys) {
          await tester.tap(find.byKey(const Key('remoteInputMode')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('键盘模拟'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('remoteTextInput')),
            findsNothing,
            reason: 'Keyboard simulation must not paint an input box',
          );
          expect(find.byType(EditableText), findsNothing);
        }
        final field = find.byKey(
          const Key('remoteTextInput'),
          skipOffstage: false,
        );
        final focus = tester.widget<TextField>(field).focusNode!;
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        if (keys) {
          await tester.tap(find.byKey(const Key('remoteModifierShift')));
          await tester.pump();
        }
        session.inputs.clear();
        final surface = find.byType(RemoteSurface);
        final centre = tester.getCenter(surface);
        await tester.tapAt(centre);
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          session.mouseEvents
              .where((e) => e.$2 & 0x1000 != 0)
              .map((e) => e.$2 & 0x9000),
          [0x9000, 0x1000],
        );
        expect(
          focus.hasFocus,
          isTrue,
          reason: 'Touching the desktop must keep IME focus',
        );
        expect(tester.testTextInput.isVisible, isTrue);
        session.inputs.clear();
        await tester.tapAt(centre);
        await tester.pump(const Duration(milliseconds: 60));
        final drag = await tester.startGesture(centre);
        await tester.pump(const Duration(milliseconds: 180));
        await drag.moveBy(const Offset(20, 10));
        await tester.pump();
        expect(
          session.mouseEvents.where((e) => e.$2 & 0x9000 == 0x9000).length,
          1,
        );
        await drag.up();
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          session.mouseEvents.where((e) => e.$2 & 0x9000 == 0x1000).length,
          1,
        );
        expect(focus.hasFocus, isTrue);
        session.inputs.clear();
        final one = await tester.startGesture(
          centre - const Offset(25, 0),
          pointer: 80,
        );
        final two = await tester.startGesture(
          centre + const Offset(25, 0),
          pointer: 81,
        );
        for (var step = 0; step < 4; step++) {
          await one.moveBy(const Offset(0, 12));
          await two.moveBy(const Offset(0, 12));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await one.up();
        await two.up();
        await tester.pump(const Duration(milliseconds: 350));
        expect(session.mouseEvents.any((e) => e.$2 & 0x0200 != 0), isTrue);
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        if (keys) {
          expect(
            session.inputs.any(
              (e) => e.$1 == 1 && e.$2 == 0x8000 && e.$3 == 0x2a,
            ),
            isFalse,
            reason: 'Remote gestures must not release a latched Shift',
          );
        }
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: keys ? '\u200bab' : '继续输入中文',
            selection: TextSelection.collapsed(offset: keys ? 3 : 6),
          ),
        );
        await tester.pump();
        if (keys) {
          expect(
            session.inputs
                .where((e) => e.$1 == 1 && e.$2 == 0)
                .map((e) => e.$3),
            [0x1e, 0x30],
          );
        } else {
          await tester.tap(find.byTooltip('发送文字'));
          await tester.pump();
          expect(session.texts, ['继续输入中文']);
        }
        await tester.tap(find.byTooltip('收起键盘'));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        if (keys) {
          expect(
            session.inputs
                .where((e) => e.$1 == 1 && e.$2 == 0x8000 && e.$3 == 0x2a)
                .length,
            1,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      });
    }
  }
}
