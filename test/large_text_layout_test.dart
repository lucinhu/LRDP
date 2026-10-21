import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/app.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/ui/remote_view.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/theme.dart';

RdpSession connectedSession() {
  final session = RdpSession(
    const ConnectionProfile(id: 'keys', name: 'Keys', host: '192.0.2.1'),
  );
  session.state = SessionState.connected;
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.black, BlendMode.src);
  final picture = recorder.endRecording();
  session.image = picture.toImageSync(800, 400);
  picture.dispose();
  return session;
}

void main() {
  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('200% phone text supports editing and settings at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore(await SharedPreferences.getInstance());
      await store.load();
      await store.save(
        const ConnectionProfile(
          id: 'large',
          name: '办公室开发工作站',
          host: '192.0.2.10',
          group: '工作',
        ),
      );
      await store.save(
        const ConnectionProfile(
          id: 'other',
          name: '家用电脑',
          host: '192.0.2.20',
          group: '个人',
        ),
      );
      await tester.pumpWidget(LrdpApp(store: store));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      try {
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      } finally {
        semantics.dispose();
      }
      final group = find.widgetWithText(ChoiceChip, '工作');
      await tester.ensureVisible(group);
      await tester.pumpAndSettle();
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(find.text('家用电脑'), findsNothing);
      final menu = find.byTooltip('连接操作');
      await tester.scrollUntilVisible(
        menu,
        80,
        scrollable: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑连接'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const Key('profileAddress')),
        '192.0.2.30',
      );
      tester.view.viewInsets = FakeViewPadding(
        bottom: size.height > 400 ? 250 : 150,
      );
      await tester.pumpAndSettle();
      final save = find.widgetWithText(OutlinedButton, '保存连接');
      expect(save.hitTestable(), findsOneWidget);
      expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        store.profiles.firstWhere((p) => p.id == 'large').host,
        '192.0.2.30',
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      final dark = find.byKey(const ValueKey('theme-system'));
      await tester.ensureVisible(dark);
      await tester.pumpAndSettle();
      await tester.tap(dark);
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色').last);
      await tester.pumpAndSettle();
      expect(store.themeMode, ThemeMode.dark);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (size, inset) in [
    (const Size(568, 320), 170.0),
    (const Size(320, 568), 360.0),
  ]) {
    testWidgets('200% keyboard error remains readable above the IME at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final session = connectedSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(
            body: RemoteView(
              session: session,
              reconnect: () {},
              disconnect: () {},
              active: true,
              toggleFullscreen: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('键盘'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remoteInputMode')));
      await tester.pumpAndSettle();
      final simulation = find.widgetWithText(MenuItemButton, '键盘模拟');
      await tester.ensureVisible(simulation);
      await tester.pumpAndSettle();
      await tester.tap(simulation);
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final error = find.textContaining('此内容无法模拟为按键');
      expect(
        tester.getSize(find.byType(RemoteSurface)).height,
        greaterThanOrEqualTo(48),
        reason:
            'The remote desktop must remain touchable while the IME and error are visible',
      );
      await tester.ensureVisible(error);
      await tester.pumpAndSettle();
      expect(error.hitTestable(), findsOneWidget);
      final close = find.byTooltip('收起键盘');
      await tester.ensureVisible(close);
      await tester.pumpAndSettle();
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remoteTextInput')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('200% desktop text dialog scrolls errors above the IME', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = connectedSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: RemoteView(
            session: session,
            reconnect: () {},
            disconnect: () {},
            active: true,
            toggleFullscreen: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('键盘'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('remoteInputMode'));
    await tester.ensureVisible(mode);
    await tester.pumpAndSettle();
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('键盘模拟'));
    await tester.pumpAndSettle();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pumpAndSettle();
    final error = find.textContaining('此内容无法模拟为按键');
    await tester.ensureVisible(error);
    await tester.pumpAndSettle();
    expect(error.hitTestable(), findsOneWidget);
    final close = find.byTooltip('收起键盘');
    await tester.ensureVisible(close);
    await tester.pumpAndSettle();
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
