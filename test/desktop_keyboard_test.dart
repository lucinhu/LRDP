import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/ui/keyboard_keys.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/remote_view.dart';
import 'package:lrdp/ui/theme.dart';

import 'remote_view_test.dart' show RecordingSession;

void main() {
  Future<RecordingSession> mount(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = RecordingSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(
          Brightness.light,
        ).copyWith(platform: TargetPlatform.linux),
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
    return session;
  }

  final panel = find.byKey(const Key('remoteKeyboardPanel'));

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('键盘'));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop keyboard is a docked panel, not a modal dialog', (
    tester,
  ) async {
    final session = await mount(tester);
    final surface = find.byType(RemoteSurface);
    final before = tester.getSize(surface);
    await open(tester);
    expect(panel, findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('屏幕键盘'), findsOneWidget);
    // The remote image stays visible and keeps its viewport; the panel floats.
    expect(tester.getSize(surface), before);
    expect(
      tester.widget<RemoteSurface>(surface).inputEnabled,
      isTrue,
      reason: 'The dock must not block remote control',
    );
    final field = find.byKey(const Key('remoteTextInput'));
    await tester.enterText(field, '你好 LRDP');
    await tester.pump();
    await tester.tap(find.byKey(const Key('pasteRemoteText')));
    await tester.pumpAndSettle();
    expect(session.texts, ['你好 LRDP']);
    expect(
      tester.widget<TextField>(field).controller!.text,
      isEmpty,
      reason: 'A sent message is cleared from the composer',
    );
    await tester.tap(find.byTooltip('收起键盘'));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the floating keyboard button toggles the desktop panel', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    expect(panel, findsOneWidget);
    await tester.tap(find.text('键盘'));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop panel groups navigation, function and combo keys', (
    tester,
  ) async {
    final session = await mount(tester);
    await open(tester);
    expect(find.text('修饰键'), findsOneWidget);
    expect(find.text('方向键'), findsOneWidget);
    expect(find.text('编辑键'), findsOneWidget);
    expect(find.byKey(const Key('remoteKeyEsc')), findsOneWidget);
    expect(find.byKey(const Key('remoteKeyF1')), findsNothing);
    expect(find.byKey(const Key('remoteKey1')), findsNothing);
    await tester.tap(find.byKey(const Key('remoteExtraKeys')));
    await tester.pumpAndSettle();
    expect(find.text('功能键'), findsOneWidget);
    expect(find.text('组合键'), findsOneWidget);
    expect(find.byKey(const Key('remoteKeyF12')), findsOneWidget);
    await tester.tap(find.byKey(const Key('remoteNumberKeys')));
    await tester.pumpAndSettle();
    expect(find.text('数字与符号'), findsOneWidget);
    expect(find.byKey(const Key('remoteKey1')), findsOneWidget);
    session.inputs.clear();
    final del = find.byKey(const Key('remoteKeyCtrl+Alt+Del'));
    await tester.ensureVisible(del);
    await tester.pumpAndSettle();
    await tester.tap(del);
    await tester.pump();
    expect(session.inputs.where((e) => e.$1 == 1).map((e) => e.$3).toList(), [
      0x1d,
      0x38,
      0x53,
      0x53,
      0x38,
      0x1d,
    ]);
  });

  testWidgets('desktop arrow buttons repeat while held', (tester) async {
    final session = await mount(tester);
    await open(tester);
    final key = find.byKey(const Key('remoteKey↑'));
    await tester.ensureVisible(key);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(key));
    await tester.pump(keyRepeatStart + const Duration(milliseconds: 20));
    expect(
      session.inputs.where((e) => e.$1 == 1 && e.$3 == 0x48),
      hasLength(2),
    );
    session.inputs.clear();
    await tester.pump(keyRepeatInterval * 2);
    expect(
      session.inputs.where((e) => e.$1 == 1 && e.$3 == 0x48),
      hasLength(4),
    );
    await gesture.up();
    await tester.pump();
    session.inputs.clear();
    await tester.pump(keyRepeatInterval * 3);
    expect(session.inputs, isEmpty);
  });

  testWidgets('Escape closes the docked panel', (tester) async {
    await mount(tester);
    await open(tester);
    expect(panel, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow desktop windows stack the composer above the keys', (
    tester,
  ) async {
    await mount(tester, size: const Size(820, 620));
    await open(tester);
    expect(panel, findsOneWidget);
    expect(find.byKey(const Key('remoteTextInput')), findsOneWidget);
    expect(find.byKey(const Key('remoteKey→')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
