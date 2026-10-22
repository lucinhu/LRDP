import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/app.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/remote_image_scaling.dart';
import 'package:lrdp/rdp/rdp_cursor.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'remote_view_test.dart' show RecordingSession;

class TextureSession extends RecordingSession {
  @override
  int? get textureId => 42;
  @override
  int get desktopWidth => 800;
  @override
  int get desktopHeight => 400;
}

void main() {
  test(
    'display and pointer preferences validate values and survive reload',
    () async {
      SharedPreferences.setMockInitialValues({
        'imageScaling': 'unknown',
        'pointerSpeed': -20,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ProfileStore(prefs);
      expect(store.pointerSpeed, 100);
      expect(store.imageScaling, RemoteImageScaling.smooth);
      await store.setPointerSpeed(150);
      await store.setImageScaling(RemoteImageScaling.sharp);
      final reloaded = ProfileStore(await SharedPreferences.getInstance());
      expect(reloaded.pointerSpeed, 150);
      expect(reloaded.imageScaling, RemoteImageScaling.sharp);
      await expectLater(store.setPointerSpeed(0), throwsArgumentError);
      expect(store.pointerSpeed, 150);
    },
  );

  Future<(TransformationController, FocusNode)> mount(
    WidgetTester tester,
    RecordingSession session, {
    int speed = 100,
    bool trackpad = true,
    RemoteImageScaling scaling = RemoteImageScaling.smooth,
    TransformationController? transform,
    FocusNode? focus,
  }) async {
    final matrix = transform ?? TransformationController();
    final node = focus ?? FocusNode();
    if (transform == null) addTearDown(matrix.dispose);
    if (focus == null) addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemoteSurface(
            session: session,
            focus: node,
            transform: matrix,
            trackpad: trackpad,
            pan: false,
            pointerSpeed: speed,
            imageScaling: scaling,
          ),
        ),
      ),
    );
    await tester.pump();
    return (matrix, node);
  }

  for (final speed in [50, 100, 200]) {
    for (final zoom in [1.0, 2.0]) {
      testWidgets(
        'touch pointer moves accurately at $speed percent and zoom $zoom',
        (tester) async {
          tester.view.physicalSize = const Size(400, 400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final session = RecordingSession();
          addTearDown(session.dispose);
          session.cursor = const RdpCursor(x: 200, y: 100, positionSerial: 1);
          final (matrix, _) = await mount(tester, session, speed: speed);
          matrix.value = Matrix4.diagonal3Values(zoom, zoom, 1);
          await tester.pump();
          final touch = await tester.startGesture(const Offset(200, 200));
          session.inputs.clear();
          await touch.moveBy(const Offset(20, 0));
          await tester.pump();
          final move = session.mouseEvents.last;
          expect(move.$2, 0x0800);
          expect(move.$3, (200 + 20 * speed / 100 / (.5 * zoom)).round());
          expect(move.$4, 100);
          await touch.up();
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('pointer speed leaves physical mouse positioning unchanged', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = RecordingSession();
    addTearDown(session.dispose);
    final (matrix, focus) = await mount(tester, session, speed: 50);
    for (final speed in [50, 200]) {
      await mount(
        tester,
        session,
        speed: speed,
        transform: matrix,
        focus: focus,
      );
      session.inputs.clear();
      await tester.sendEventToBinding(
        const PointerHoverEvent(
          position: Offset(200, 200),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump();
      expect(session.mouseEvents.last, (0, 0x0800, 400, 200));
    }
    await tester.pumpWidget(const SizedBox());
  });

  for (final texture in [false, true]) {
    testWidgets(
      'scaling preference updates ${texture ? 'texture' : 'image'} without moving the viewport',
      (tester) async {
        final session = texture ? TextureSession() : RecordingSession();
        addTearDown(session.dispose);
        final (matrix, focus) = await mount(tester, session);
        matrix.value = Matrix4.diagonal3Values(1.5, 1.5, 1);
        await tester.pump();
        final saved = matrix.value.clone();
        for (final mode in RemoteImageScaling.values) {
          await mount(
            tester,
            session,
            scaling: mode,
            transform: matrix,
            focus: focus,
          );
          final quality = texture
              ? tester.widget<Texture>(find.byType(Texture)).filterQuality
              : tester.widget<RawImage>(find.byType(RawImage)).filterQuality;
          expect(
            quality,
            mode == RemoteImageScaling.sharp
                ? FilterQuality.none
                : FilterQuality.low,
          );
          expect(matrix.value, saved);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final (locale, settings, sharp) in [
    ('zh-CN', '设置', '锐利像素'),
    ('zh-TW', '設定', '銳利像素'),
    ('en', 'Settings', 'Sharp pixels'),
  ]) {
    testWidgets(
      'new settings remain usable at 200% on a small phone: $locale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        SharedPreferences.setMockInitialValues({'language': locale});
        final store = ProfileStore(await SharedPreferences.getInstance());
        await tester.pumpWidget(LrdpApp(store: store));
        await tester.pumpAndSettle();
        await tester.tap(find.text(settings).last);
        await tester.pumpAndSettle();
        Future<void> show(Finder target) async {
          await tester.scrollUntilVisible(
            target,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
        }

        final scaling = find.byKey(const ValueKey('image-scaling-smooth'));
        await show(scaling);
        await tester.tap(scaling);
        await tester.pumpAndSettle();
        await tester.tap(find.text(sharp).last);
        await tester.pumpAndSettle();
        expect(store.imageScaling, RemoteImageScaling.sharp);
        final speed = find.byKey(const ValueKey('pointer-speed-100'));
        await show(speed);
        await tester.tap(speed);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('200%').last);
        await tester.tap(find.text('200%').last);
        await tester.pumpAndSettle();
        expect(store.pointerSpeed, 200);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
