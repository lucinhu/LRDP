import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/rdp/rdp_cursor.dart';
import 'package:lrdp/rdp/session_recovery.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/remote_view.dart';
import 'package:lrdp/ui/remote_view_memory.dart';
import 'package:lrdp/ui/theme.dart';

class RecordingSession extends RdpSession {
  RecordingSession({bool automaticResolution = true})
    : super(
        ConnectionProfile(
          id: 'touch',
          name: '测试电脑',
          host: '192.0.2.1',
          automaticResolution: automaticResolution,
        ),
      ) {
    state = SessionState.connected;
    features = 8;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(const Color(0xff182d28), BlendMode.src);
    final picture = recorder.endRecording();
    image = picture.toImageSync(800, 400);
    picture.dispose();
  }
  final inputs = <(int, int, int, int)>[];
  final texts = <String>[];
  @override
  void input(int type, int a, [int b = 0, int c = 0]) =>
      inputs.add((type, a, b, c));
  @override
  void text(String text) => texts.add(text);
  List<(int, int, int, int)> get mouseEvents =>
      inputs.where((e) => e.$1 == 0).toList();
}

class ClipboardRecordingSession extends RecordingSession {
  ClipboardRecordingSession() {
    features |= 1;
  }
  final pasted = <String>[];
  final announced = <String>[];
  @override
  Future<bool> paste(String text) async {
    pasted.add(text);
    return true;
  }

  @override
  void clipboard(String text) => announced.add(text);
}

void main() {
  for (final payload in ['本机复制的中文 😀', '', null]) {
    testWidgets('paste local clipboard reads text explicitly: $payload', (
      tester,
    ) async {
      final session = ClipboardRecordingSession();
      addTearDown(session.dispose);
      final reads = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            reads.add(call.arguments as String);
            return payload == null ? null : {'text': payload};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
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
      // A pending remote update must not overwrite the user's local payload.
      session.remoteClipboard = '远端原有内容';
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('粘贴本机文字'));
      await tester.pumpAndSettle();
      expect(reads, ['text/plain']);
      expect(session.announced, isEmpty);
      expect(
        session.pasted,
        payload == null || payload.isEmpty ? [] : [payload],
      );
      expect(
        find.textContaining(
          payload == null || payload.isEmpty ? '本机剪贴板没有文字' : '已向远程电脑发送粘贴',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'auto size follows the viewport, debounces rotation and holds during IME',
    (tester) async {
      tester.view.physicalSize = const Size(410, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = RecordingSession()..features = 10;
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
      await tester.pump(const Duration(milliseconds: 500));
      List<(int, int, int, int)> sizes() =>
          session.inputs.where((e) => e.$1 == 3).toList();
      final surface = tester.getSize(find.byType(RemoteSurface));
      expect(sizes().last, (3, 410, surface.height.round(), 0));
      final count = sizes().length;
      await tester.tap(find.text('键盘'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(sizes().length, count);
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      // Close the composer before rotating; opening/closing it itself never
      // changes the requested size, even while the IME is animating.
      await tester.tap(find.byTooltip('收起键盘'));
      await tester.pumpAndSettle();
      expect(sizes().length, count);
      tester.view.physicalSize = const Size(850, 410);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      tester.view.physicalSize = const Size(900, 410);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 399));
      expect(sizes().length, count);
      await tester.pump(const Duration(milliseconds: 1));
      expect(sizes().length, count + 1);
      expect(sizes().last.$2, 900);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('fixed size and missing server capability never auto resize', (
    tester,
  ) async {
    for (final automatic in [true, false]) {
      final session = RecordingSession(automaticResolution: automatic)
        ..features = automatic ? 8 : 10;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteView(
              key: ValueKey(session),
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
      session.setViewportSize(1700, 900);
      await tester.pump(const Duration(seconds: 1));
      expect(session.inputs.where((e) => e.$1 == 3), isEmpty);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    }
  });
  testWidgets(
    'viewport and local cursor survive remount, layout and resolution changes',
    (tester) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = RecordingSession();
      session.connectedAt = DateTime(2026);
      session.cursor = const RdpCursor(x: 550, y: 240, positionSerial: 1);
      final memory = RemoteSurfaceMemory();
      final focus = FocusNode();
      var transform = TransformationController();
      Future<void> mount(Size viewport) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox.fromSize(
                  size: viewport,
                  child: ListenableBuilder(
                    listenable: session,
                    builder: (context, _) => Focus(
                      focusNode: focus,
                      child: RemoteSurface(
                        session: session,
                        focus: focus,
                        transform: transform,
                        trackpad: true,
                        pan: false,
                        memory: memory,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      void checkCenter(Offset expected) {
        final size = tester.getSize(find.byType(RemoteSurface));
        final image = session.image!;
        final scale = size.width / image.width < size.height / image.height
            ? size.width / image.width
            : size.height / image.height;
        final fitted = Offset(image.width * scale, image.height * scale);
        final origin = (Offset(size.width, size.height) - fitted) / 2;
        final point =
            (MatrixUtils.transformPoint(
                  Matrix4.inverted(transform.value),
                  size.center(Offset.zero),
                ) -
                origin) /
            scale;
        expect(point.dx / image.width, closeTo(expected.dx, 1e-8));
        expect(point.dy / image.height, closeTo(expected.dy, 1e-8));
        expect(transform.value.getMaxScaleOnAxis(), closeTo(3, 1e-8));
      }

      Future<void> clickAtCursor(int x, int y) async {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tapAt(tester.getCenter(find.byType(RemoteSurface)));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          (session.mouseEvents.last.$3, session.mouseEvents.last.$4),
          (x, y),
        );
      }

      await mount(const Size(400, 300));
      transform.value = Matrix4.diagonal3Values(3, 3, 1)
        ..setTranslationRaw(-580, -330, 0);
      await tester.pump();
      final finger = await tester.startGesture(
        tester.getCenter(find.byType(RemoteSurface)),
      );
      await finger.moveBy(const Offset(24, 0));
      await finger.up();
      await clickAtCursor(566, 240);
      checkCenter(const Offset(.65, .55));
      await tester.pumpWidget(const SizedBox());
      transform.dispose();
      transform = TransformationController();
      session.inputs.clear();
      await mount(const Size(600, 300));
      expect(session.inputs, isEmpty, reason: 'Restoring must send no input');
      checkCenter(const Offset(.65, .55));
      await clickAtCursor(566, 240);
      // Same connection: the last server position is already consumed. It
      // must not overwrite the user's later local pointer after remount.
      await mount(const Size(400, 300));
      checkCenter(const Offset(.65, .55));
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xff182d28), BlendMode.src);
      final picture = recorder.endRecording();
      session.image!.dispose();
      session.image = picture.toImageSync(1600, 800);
      picture.dispose();
      session.notifyListeners();
      await tester.pumpAndSettle();
      checkCenter(const Offset(.65, .55));
      await clickAtCursor(
        (566 / 799 * 1599).round(),
        (240 / 399 * 799).round(),
      );
      await tester.pumpWidget(const SizedBox());
      transform.dispose();
      transform = TransformationController();
      // A new connection may reuse its position serial; its fresh position
      // takes precedence over UI memory from the previous connection.
      session.connectedAt = DateTime(2026, 2);
      session.cursor = const RdpCursor(x: 200, y: 100, positionSerial: 1);
      await mount(const Size(600, 300));
      await clickAtCursor(200, 100);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 900,
      );
      await mouse.addPointer(
        location: tester.getCenter(find.byType(RemoteSurface)),
      );
      await tester.pump();
      session.cursor = const RdpCursor(x: 1050, y: 460, positionSerial: 2);
      session.notifyListeners();
      await tester.pump(const Duration(milliseconds: 350));
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(RemoteSurface)),
      );
      await touch.moveBy(const Offset(18, 0));
      await touch.up();
      await clickAtCursor(1066, 460);
      await tester.pumpWidget(const SizedBox());
      transform.dispose();
      transform = TransformationController();
      await mount(const Size(600, 300));
      // A stationary paired mouse generates MouseRegion.onEnter when the
      // view returns. Only actual movement should take over the touch cursor.
      await clickAtCursor(1066, 460);
      session.inputs.clear();
      await tester.sendEventToBinding(
        PointerHoverEvent(
          kind: PointerDeviceKind.touch,
          device: 99,
          position: tester.getCenter(find.byType(RemoteSurface)),
          delta: const Offset(-40, 0),
        ),
      );
      await tester.pump();
      expect(
        session.mouseEvents,
        isEmpty,
        reason: 'Touch hover must not move the remote mouse',
      );
      await clickAtCursor(1066, 460);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      transform.dispose();
      focus.dispose();
      session.dispose();
    },
  );

  testWidgets(
    'cursor hotspot and XOR use the actual desktop pixels under zoom',
    (tester) async {
      tester.view.physicalSize = const Size(400, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = RecordingSession();
      final focus = FocusNode();
      final transform = TransformationController();
      final repaint = GlobalKey();
      ui.Image cursorPlane(bool inverse) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          Rect.fromLTWH(inverse ? 3 : 0, 0, 1, 1),
          Paint()..color = inverse ? Colors.white : Colors.red,
        );
        final picture = recorder.endRecording();
        final image = picture.toImageSync(8, 8);
        picture.dispose();
        return image;
      }

      final normal = cursorPlane(false), inverse = cursorPlane(true);
      session.cursor = RdpCursor(
        kind: RdpCursorKind.bitmap,
        image: normal,
        inversion: inverse,
        hotX: 3,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: repaint,
              child: ListenableBuilder(
                listenable: session,
                builder: (context, _) => Focus(
                  focusNode: focus,
                  child: RemoteSurface(
                    session: session,
                    focus: focus,
                    transform: transform,
                    trackpad: true,
                    pan: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<List<int>> pixel(int x, int y) async {
        return (await tester.runAsync(() async {
          final image =
              await (repaint.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            return data!.buffer.asUint8List().sublist(
              (y * image.width + x) * 4,
              (y * image.width + x) * 4 + 4,
            );
          } finally {
            image.dispose();
          }
        }))!;
      }

      expect(await pixel(200, 200), [
        231,
        210,
        215,
        255,
      ], reason: 'XOR must invert the real desktop');
      expect(
        await pixel(197, 200),
        [244, 67, 54, 255],
        reason: 'Normal cursor pixel must be offset by its hotspot',
      );
      expect(
        await pixel(201, 200),
        [24, 45, 40, 255],
        reason: 'Transparent cursor pixels preserve the desktop',
      );
      transform.value = Matrix4.diagonal3Values(2, 2, 1)
        ..setTranslationRaw(-200, -200, 0);
      await tester.pump();
      expect(await pixel(200, 200), [231, 210, 215, 255]);
      await tester.tapAt(const Offset(100, 180));
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.mouseEvents.where((e) => e.$2 & 0x1000 != 0).last.$3, 400);
      expect(session.mouseEvents.where((e) => e.$2 & 0x1000 != 0).last.$4, 200);
      session.cursor = const RdpCursor(kind: RdpCursorKind.hidden);
      session.notifyListeners();
      await tester.pump();
      expect(await pixel(200, 200), [24, 45, 40, 255]);
      normal.dispose();
      inverse.dispose();
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
      transform.dispose();
      session.dispose();
    },
  );

  testWidgets(
    'server position applies once and shape changes do not undo local trackpad motion',
    (tester) async {
      tester.view.physicalSize = const Size(400, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = RecordingSession();
      final focus = FocusNode();
      final transform = TransformationController();
      session.cursor = const RdpCursor(x: 100, y: 100, positionSerial: 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: session,
              builder: (context, _) => Focus(
                focusNode: focus,
                child: RemoteSurface(
                  session: session,
                  focus: focus,
                  transform: transform,
                  trackpad: true,
                  pan: false,
                ),
              ),
            ),
          ),
        ),
      );
      final finger = await tester.startGesture(const Offset(100, 200));
      await finger.moveBy(const Offset(20, 0));
      await finger.up();
      await tester.pump();
      expect(session.mouseEvents.last.$3, 140);
      expect(session.mouseEvents.last.$4, 100);
      session.cursor = const RdpCursor(x: 100, y: 100, positionSerial: 1);
      session.notifyListeners();
      await tester.pump();
      await tester.tapAt(const Offset(100, 200));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        session.mouseEvents.last.$3,
        140,
        reason: 'A shape-only update must not warp back',
      );
      session.cursor = const RdpCursor(x: 50, y: 60, positionSerial: 2);
      session.notifyListeners();
      await tester.pump();
      await tester.tapAt(const Offset(100, 200));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        (session.mouseEvents.last.$3, session.mouseEvents.last.$4),
        (50, 60),
      );
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
      transform.dispose();
      session.dispose();
    },
  );

  testWidgets(
    'phone recovery controls remain usable with safe areas and large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.reset);
      final session = RecordingSession();
      var retries = 0;
      final recovery = SessionRecovery(
        session,
        reconnect: () async {
          retries++;
        },
      );
      session.state = SessionState.failed;
      session.endReason = SessionEndReason.transport;
      session.error = 'Network connection lost';
      session.notifyListeners();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(
            Brightness.light,
          ).copyWith(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: Scaffold(
            body: SafeArea(
              child: RemoteView(
                session: session,
                recovery: recovery,
                active: true,
                reconnect: () {},
                disconnect: () {},
                toggleFullscreen: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('立即重连').hitTestable(), findsOneWidget);
      expect(find.text('取消重连').hitTestable(), findsOneWidget);
      final cancel = find.widgetWithText(OutlinedButton, '取消重连');
      expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
      expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(544));
      await tester.tap(cancel);
      await tester.pump(const Duration(seconds: 2));
      expect(retries, 0);
      expect(find.text('重新连接'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      recovery.dispose();
      session.dispose();
    },
  );

  testWidgets('phone more menu exposes disconnect above the gesture area', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 1.75;
    tester.view.padding = const FakeViewPadding(top: 136, bottom: 42);
    addTearDown(tester.view.reset);
    final session = RecordingSession();
    addTearDown(session.dispose);
    var disconnected = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(
          Brightness.light,
        ).copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: SafeArea(
            child: RemoteView(
              session: session,
              active: true,
              reconnect: () {},
              disconnect: () => disconnected = true,
              toggleFullscreen: () {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    expect(find.text('断开连接').hitTestable(), findsOneWidget);
    expect(
      tester.getRect(find.text('断开连接')).bottom,
      lessThanOrEqualTo((1600 - 42) / 1.75),
    );
    await tester.tap(find.text('断开连接'));
    await tester.pumpAndSettle();
    expect(disconnected, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  Future<(RecordingSession, TransformationController, FocusNode)> surface(
    WidgetTester tester, {
    bool trackpad = false,
    bool pan = false,
    ValueNotifier<bool>? activity,
  }) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = RecordingSession();
    final transform = TransformationController();
    final focus = FocusNode();
    final active = activity ?? ValueNotifier(true);
    if (activity == null) addTearDown(active.dispose);
    addTearDown(() {
      transform.dispose();
      focus.dispose();
      session.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, active, _) => Focus(
              focusNode: focus,
              child: RemoteSurface(
                session: session,
                focus: focus,
                transform: transform,
                trackpad: trackpad,
                pan: pan,
                active: active,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (session, transform, focus);
  }

  for (final relative in [false, true]) {
    testWidgets(
      'physical trackpad retains slow diagonal scroll in mode $relative',
      (tester) async {
        final (session, transform, _) = await surface(
          tester,
          trackpad: relative,
        );
        final original = transform.value.clone();
        final pointer = TestPointer(51, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(
          pointer.panZoomStart(const Offset(200, 200)),
        );
        for (var i = 1; i <= 48; i++) {
          await tester.sendEventToBinding(
            pointer.panZoomUpdate(
              const Offset(200, 200),
              pan: Offset(i / 2, -i.toDouble()),
            ),
          );
        }
        await tester.sendEventToBinding(pointer.panZoomEnd());
        expect(session.mouseEvents, [
          (0, 0x388, 0, 0),
          (0, 0x388, 0, 0),
          (0, 0x588, 0, 0),
        ]);
        expect(transform.value, original);
        // Fractions from the previous sequence must not spill into a new one.
        session.inputs.clear();
        await tester.sendEventToBinding(
          pointer.panZoomStart(const Offset(200, 200)),
        );
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(
            const Offset(200, 200),
            pan: const Offset(0, 23),
          ),
        );
        await tester.sendEventToBinding(pointer.panZoomEnd());
        expect(session.mouseEvents, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('physical trackpad pinch zooms without remote wheel or clicks', (
    tester,
  ) async {
    final (session, transform, _) = await surface(tester);
    final pointer = TestPointer(51, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(
      pointer.panZoomStart(const Offset(200, 200)),
    );
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(
        const Offset(200, 200),
        pan: const Offset(20, 30),
        scale: 1.5,
      ),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());
    expect(transform.value.getMaxScaleOnAxis(), closeTo(1.5, .001));
    expect(session.mouseEvents, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'physical trackpad stops across background and session switches',
    (tester) async {
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final (session, _, _) = await surface(tester, activity: active);
      final pointer = TestPointer(51, PointerDeviceKind.trackpad);
      for (final background in [true, false]) {
        await tester.sendEventToBinding(
          pointer.panZoomStart(const Offset(200, 200)),
        );
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(
            const Offset(200, 200),
            pan: const Offset(0, 20),
          ),
        );
        if (background) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        } else {
          active.value = false;
        }
        await tester.pump();
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(
            const Offset(200, 200),
            pan: const Offset(0, 120),
          ),
        );
        await tester.sendEventToBinding(pointer.panZoomEnd());
        expect(session.mouseEvents, isEmpty);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('direct tap maps coordinates and long press sends right button', (
    tester,
  ) async {
    final (session, _, _) = await surface(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump(const Duration(milliseconds: 300));
    expect(session.mouseEvents, [(0, 0x9800, 200, 100), (0, 0x1800, 200, 100)]);
    await tester.pump(const Duration(milliseconds: 350));
    session.inputs.clear();
    final touch = await tester.startGesture(const Offset(100, 150));
    await tester.pump(const Duration(milliseconds: 600));
    await touch.up();
    expect(session.mouseEvents, [(0, 0xa800, 200, 100), (0, 0x2800, 200, 100)]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pinch keeps cursor coordinates correct and sends no remote click',
    (tester) async {
      final (session, transform, _) = await surface(tester);
      final first = await tester.startGesture(
        const Offset(160, 200),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(240, 200),
        pointer: 2,
      );
      await first.moveTo(const Offset(120, 200));
      await second.moveTo(const Offset(280, 200));
      await first.up();
      await second.up();
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), closeTo(2, .001));
      expect(session.mouseEvents, isEmpty);
      await tester.tapAt(const Offset(100, 150));
      await tester.pump(const Duration(milliseconds: 300));
      expect(session.mouseEvents, [
        (0, 0x9800, 300, 150),
        (0, 0x1800, 300, 150),
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('two fingers scroll without clicks or pointer movement', (
    tester,
  ) async {
    final (session, transform, _) = await surface(tester, trackpad: true);
    final first = await tester.startGesture(const Offset(120, 240), pointer: 1);
    final second = await tester.startGesture(
      const Offset(280, 240),
      pointer: 2,
    );
    for (var step = 1; step <= 4; step++) {
      await first.moveTo(Offset(120, 240 - step * 12));
      await second.moveTo(Offset(280, 240 - step * 12));
    }
    await first.up();
    await second.up();
    expect(session.mouseEvents, isNotEmpty);
    expect(
      session.mouseEvents.every((e) => e.$2 == 0x0200 | 0x0100 | (512 - 120)),
      isTrue,
    );
    expect(transform.value.getMaxScaleOnAxis(), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'trackpad double tap drag and cancellation always release button',
    (tester) async {
      final (session, _, _) = await surface(tester, trackpad: true);
      await tester.tapAt(const Offset(100, 200));
      await tester.pump(const Duration(milliseconds: 50));
      session.inputs.clear();
      final drag = await tester.startGesture(const Offset(100, 200));
      await drag.moveBy(const Offset(30, 20));
      await drag.cancel();
      expect(session.mouseEvents.first, (0, 0x9800, 400, 200));
      expect(session.mouseEvents.last, (0, 0x1800, 460, 240));
      expect(session.mouseEvents.where((e) => e.$2 == 0x0800), isNotEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final trackpad in [false, true]) {
    for (final hold in [false, true]) {
      testWidgets(
        'tap-hold drag sends only one press: trackpad=$trackpad hold=$hold',
        (tester) async {
          final (session, _, _) = await surface(tester, trackpad: trackpad);
          await tester.tapAt(const Offset(100, 200));
          await tester.pump(const Duration(milliseconds: 90));
          expect(
            session.mouseEvents,
            isEmpty,
            reason: 'The gesture prefix must not become a remote first click',
          );
          final drag = await tester.startGesture(const Offset(100, 200));
          if (hold) await tester.pump(const Duration(milliseconds: 160));
          await drag.moveBy(const Offset(40, 20));
          expect(
            session.mouseEvents
                .where((e) => e.$2 & 0x1000 != 0)
                .map((e) => e.$2),
            [0x9800],
          );
          await drag.up();
          await tester.pump(const Duration(milliseconds: 600));
          expect(
            session.mouseEvents
                .where((e) => e.$2 & 0x1000 != 0)
                .map((e) => e.$2),
            [0x9800, 0x1800],
            reason:
                'No preceding click or delayed click may turn the drag into a double click',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    testWidgets(
      'quick double tap still sends two complete clicks: trackpad=$trackpad',
      (tester) async {
        final (session, _, _) = await surface(tester, trackpad: trackpad);
        await tester.tapAt(const Offset(100, 200));
        await tester.pump(const Duration(milliseconds: 90));
        await tester.tapAt(const Offset(100, 200));
        await tester.pump(const Duration(milliseconds: 600));
        expect(session.mouseEvents.map((e) => e.$2), [
          0x9800,
          0x1800,
          0x9800,
          0x1800,
        ]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'opening a local keyboard delivers a pending remote field tap once',
    (tester) async {
      final (session, _, focus) = await surface(tester);
      await tester.tapAt(const Offset(100, 150));
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.mouseEvents, isEmpty);
      focus.unfocus();
      await tester.pump();
      expect(session.mouseEvents, [
        (0, 0x9800, 200, 100),
        (0, 0x1800, 200, 100),
      ]);
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.mouseEvents.length, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('hardware mouse releases when remote focus is lost', (
    tester,
  ) async {
    final (session, _, focus) = await surface(tester);
    final mouse = await tester.startGesture(
      const Offset(100, 150),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    focus.unfocus();
    await tester.pump();
    expect(session.mouseEvents.last, (0, 0x1800, 200, 100));
    await mouse.up();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'hardware button changes on stationary move release each button',
    (tester) async {
      final (session, _, _) = await surface(tester);
      final mouse = await tester.startGesture(
        const Offset(100, 150),
        kind: PointerDeviceKind.mouse,
        pointer: 71,
      );
      await mouse.updateWithCustomEvent(
        const PointerMoveEvent(
          device: 1,
          pointer: 71,
          kind: PointerDeviceKind.mouse,
          position: Offset(100, 150),
          buttons: kPrimaryButton | kSecondaryButton,
        ),
      );
      await mouse.updateWithCustomEvent(
        const PointerMoveEvent(
          device: 1,
          pointer: 71,
          kind: PointerDeviceKind.mouse,
          position: Offset(100, 150),
          buttons: kSecondaryButton,
        ),
      );
      await mouse.up();
      expect(session.mouseEvents.where((e) => e.$2 & 0x7000 != 0), [
        (0, 0x9800, 200, 100),
        (0, 0xa800, 200, 100),
        (0, 0x1800, 200, 100),
        (0, 0x2800, 200, 100),
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'hardware release uses the up position and next click still works',
    (tester) async {
      final (session, _, _) = await surface(tester);
      final mouse = await tester.startGesture(
        const Offset(100, 150),
        kind: PointerDeviceKind.mouse,
        pointer: 72,
      );
      await mouse.moveTo(const Offset(130, 160));
      // GTK can coalesce the final motion into the release packet.
      await mouse.updateWithCustomEvent(
        const PointerUpEvent(
          device: 1,
          pointer: 72,
          kind: PointerDeviceKind.mouse,
          position: Offset(150, 180),
        ),
      );
      expect(session.mouseEvents.last, (0, 0x1800, 300, 160));
      await tester.tapAt(const Offset(180, 190), kind: PointerDeviceKind.mouse);
      expect(
        session.mouseEvents
            .where((e) => e.$2 & 0x7000 != 0)
            .toList()
            .sublist(2),
        [(0, 0x9800, 360, 180), (0, 0x1800, 360, 180)],
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('returning hardware hover recovers a missing release once', (
    tester,
  ) async {
    final (session, _, _) = await surface(tester);
    final mouse = await tester.startGesture(
      const Offset(100, 150),
      kind: PointerDeviceKind.mouse,
      pointer: 73,
    );
    await mouse.moveTo(const Offset(130, 160));
    session.inputs.clear();
    // The platform lost Up outside the application; use the actual buttons=0
    // hover returning to the surface as evidence, without inventing a new Down.
    await tester.sendEventToBinding(
      const PointerHoverEvent(
        device: 1,
        kind: PointerDeviceKind.mouse,
        position: Offset(160, 170),
      ),
    );
    await tester.sendEventToBinding(
      const PointerHoverEvent(
        device: 1,
        kind: PointerDeviceKind.mouse,
        position: Offset(170, 180),
      ),
    );
    expect(session.mouseEvents.where((e) => e.$2 & 0x7000 != 0), [
      (0, 0x1800, 260, 120),
    ]);
    await mouse.up();
    expect(session.mouseEvents.where((e) => e.$2 & 0x7000 != 0).length, 1);
    await tester.tapAt(const Offset(180, 190), kind: PointerDeviceKind.mouse);
    expect(session.mouseEvents.last, (0, 0x1800, 360, 180));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('focus cancellation does not re-press on a held mouse move', (
    tester,
  ) async {
    final (session, _, focus) = await surface(tester);
    final mouse = await tester.startGesture(
      const Offset(100, 150),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    focus.unfocus();
    await tester.pump();
    session.inputs.clear();
    await mouse.moveTo(const Offset(140, 170));
    await mouse.up();
    expect(session.mouseEvents.where((e) => e.$2 & 0x7000 != 0), isEmpty);
    await tester.tapAt(const Offset(180, 190), kind: PointerDeviceKind.mouse);
    expect(session.mouseEvents.last, (0, 0x1800, 360, 180));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('two-finger tap sends one right click after a recent left tap', (
    tester,
  ) async {
    final (session, _, _) = await surface(tester, trackpad: true);
    await tester.tapAt(const Offset(120, 200));
    await tester.pump(const Duration(milliseconds: 50));
    session.inputs.clear();
    final first = await tester.startGesture(const Offset(120, 200), pointer: 1);
    final second = await tester.startGesture(
      const Offset(240, 200),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 80));
    await first.up();
    expect(session.mouseEvents, [(0, 0x9800, 400, 200), (0, 0x1800, 400, 200)]);
    await second.up();
    expect(session.mouseEvents, [
      (0, 0x9800, 400, 200),
      (0, 0x1800, 400, 200),
      (0, 0xa800, 400, 200),
      (0, 0x2800, 400, 200),
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('held, cancelled and three-finger touches do not right click', (
    tester,
  ) async {
    final (session, _, _) = await surface(tester, trackpad: true);
    for (final mode in ['held', 'cancelled', 'third']) {
      final first = await tester.startGesture(
        const Offset(120, 200),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(240, 200),
        pointer: 2,
      );
      if (mode == 'held') await tester.pump(const Duration(milliseconds: 400));
      if (mode == 'cancelled') await first.cancel();
      if (mode == 'third') {
        final third = await tester.startGesture(
          const Offset(280, 200),
          pointer: 3,
        );
        await third.up();
      }
      if (mode != 'cancelled') await first.up();
      await second.up();
      expect(session.mouseEvents, isEmpty, reason: mode);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'close two-finger horizontal swipes scroll without accidental pinch',
    (tester) async {
      final (session, transform, _) = await surface(tester, trackpad: true);
      final first = await tester.startGesture(
        const Offset(150, 200),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(210, 200),
        pointer: 2,
      );
      for (var step = 1; step <= 4; step++) {
        await first.moveTo(Offset(150 - step * 12, 200));
        await second.moveTo(Offset(210 - step * 12, 200));
      }
      await first.up();
      await second.up();
      expect(transform.value.getMaxScaleOnAxis(), 1);
      expect(session.mouseEvents, [
        (0, 0x0400 | 120, 0, 0),
        (0, 0x0400 | 120, 0, 0),
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('pinch with one stationary finger updates before touch release', (
    tester,
  ) async {
    final (session, transform, _) = await surface(tester, trackpad: true);
    final first = await tester.startGesture(const Offset(160, 200), pointer: 1);
    final second = await tester.startGesture(
      const Offset(240, 200),
      pointer: 2,
    );
    await first.moveTo(const Offset(120, 200));
    await tester.pump(const Duration(milliseconds: 20));
    expect(transform.value.getMaxScaleOnAxis(), closeTo(1.5, .001));
    expect(session.mouseEvents, isEmpty);
    await first.up();
    await second.up();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'trackpad follows the cursor at zoomed edges and keeps drag coordinates',
    (tester) async {
      final (session, transform, _) = await surface(tester, trackpad: true);
      transform.value = Matrix4.diagonal3Values(3, 3, 1)
        ..setTranslationRaw(-400, -400, 0);
      await tester.pump();
      await tester.tapAt(const Offset(120, 200));
      await tester.pump(const Duration(milliseconds: 50));
      session.inputs.clear();
      final drag = await tester.startGesture(const Offset(120, 200));
      await drag.moveTo(const Offset(390, 200));
      expect(transform.value.storage[12], lessThan(-400));
      final move = session.mouseEvents.last;
      expect(move, (0, 0x0800, 580, 200));
      final screen = MatrixUtils.transformPoint(
        transform.value,
        Offset(move.$3 * .5, 100 + move.$4 * .5),
      );
      expect(screen.dx, closeTo(364, .001));
      expect(screen.dy, closeTo(200, .001));
      await drag.up();
      expect(session.mouseEvents.first, (0, 0x9800, 400, 200));
      expect(session.mouseEvents.last, (0, 0x1800, 580, 200));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'hardware pointer near an edge pans continuously and stops in the centre',
    (tester) async {
      final (session, transform, _) = await surface(tester);
      transform.value = Matrix4.diagonal3Values(2, 2, 1)
        ..setTranslationRaw(-200, -200, 0);
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(200, 200));
      await mouse.moveTo(const Offset(398, 200));
      await tester.pump(const Duration(milliseconds: 320));
      expect(transform.value.storage[12], lessThan(-250));
      expect(session.mouseEvents.last.$3, greaterThan(598));
      await mouse.moveTo(const Offset(200, 200));
      final stopped = transform.value.clone();
      await tester.pump(const Duration(milliseconds: 320));
      expect(transform.value, stopped);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'panning clamps to the desktop bounds and centres an axis that fits',
    (tester) async {
      final (_, transform, _) = await surface(
        tester,
        trackpad: true,
        pan: true,
      );
      transform.value = Matrix4.diagonal3Values(1.5, 1.5, 1)
        ..setTranslationRaw(-100, -100, 0);
      await tester.pump();
      final drag = await tester.startGesture(const Offset(200, 200));
      await drag.moveTo(const Offset(390, 390));
      expect(transform.value.storage[12], closeTo(0, .001));
      expect(transform.value.storage[13], closeTo(-100, .001));
      await drag.moveTo(const Offset(0, 0));
      expect(transform.value.storage[12], closeTo(-200, .001));
      expect(transform.value.storage[13], closeTo(-100, .001));
      await drag.up();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'viewport resize keeps the zoomed desktop within its new bounds',
    (tester) async {
      final (_, transform, _) = await surface(tester, trackpad: true);
      transform.value = Matrix4.diagonal3Values(2, 2, 1)
        ..setTranslationRaw(-400, -200, 0);
      await tester.pump();
      tester.view.physicalSize = const Size(400, 800);
      await tester.pump();
      await tester.pump();
      expect(transform.value.storage[12], closeTo(-400, .001));
      expect(transform.value.storage[13], closeTo(-400, .001));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'inactive session releases dragging and ignores new touch and wheel input',
    (tester) async {
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final (session, _, _) = await surface(
        tester,
        trackpad: true,
        activity: active,
      );
      await tester.tapAt(const Offset(120, 200));
      await tester.pump(const Duration(milliseconds: 50));
      final drag = await tester.startGesture(const Offset(120, 200));
      await drag.moveBy(const Offset(30, 20));
      active.value = false;
      await tester.pump();
      expect(session.mouseEvents.last, (0, 0x1800, 460, 240));
      session.inputs.clear();
      await drag.up();
      await tester.tapAt(const Offset(120, 200));
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 200),
          scrollDelta: Offset(0, 40),
        ),
      );
      expect(session.mouseEvents, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'background stops edge panning and releases a held hardware button',
    (tester) async {
      final (session, transform, _) = await surface(tester);
      transform.value = Matrix4.diagonal3Values(2, 2, 1)
        ..setTranslationRaw(-200, -200, 0);
      await tester.pump();
      final mouse = await tester.startGesture(
        const Offset(200, 200),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(const Offset(398, 200));
      await tester.pump(const Duration(milliseconds: 64));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(session.mouseEvents.last.$2, 0x1800);
      final stopped = transform.value.clone();
      session.inputs.clear();
      await tester.pump(const Duration(milliseconds: 320));
      expect(transform.value, stopped);
      expect(session.mouseEvents, isEmpty);
      await mouse.up();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets(
      'phone dock, Chinese composition, shortcuts and keyboard insets at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewInsets);
        final session = RecordingSession();
        addTearDown(session.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: SafeArea(
                child: RemoteView(
                  session: session,
                  active: true,
                  reconnect: () {},
                  disconnect: () {},
                  toggleFullscreen: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('触控板'), findsOneWidget);
        expect(
          tester.getSize(find.text('键盘').hitTestable()).width,
          greaterThan(0),
        );
        await tester.tap(find.byType(RemoteSurface));
        await tester.pumpAndSettle();
        await tester.tap(find.text('键盘'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
          reason:
              'Opening the keyboard must take focus from the remote surface',
        );
        tester.view.viewInsets = FakeViewPadding(
          bottom: size.height < 500 ? 240 : 280,
        );
        await tester.pumpAndSettle();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'zhong',
            composing: TextRange(start: 0, end: 5),
          ),
        );
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '发送文字',
                ),
              )
              .onPressed,
          isNotNull,
        );
        expect(session.texts, isEmpty);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '中文输入测试',
            selection: TextSelection.collapsed(offset: 6),
          ),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('发送文字'));
        await tester.pump();
        expect(session.texts, ['中文输入测试']);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
          reason:
              'Sending text must keep the composer ready for the next phrase',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('remoteTextInput')))
              .controller!
              .text,
          isEmpty,
        );
        if (size.height > 600) {
          await tester.tap(find.text('Ctrl+C'));
          expect(
            session.inputs.where((e) => e.$1 == 1).map((e) => (e.$2, e.$3)),
            [(0, 0x1d), (0, 0x2e), (0x8000, 0x2e), (0x8000, 0x1d)],
          );
        }
        await tester.tap(find.byKey(const Key('remoteInputMode')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('键盘模拟'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('回车').hitTestable(), findsOneWidget);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '中文',
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump();
        expect(find.textContaining('键盘模拟请使用英文输入法'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('收起键盘'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('收起键盘'));
        await tester.pumpAndSettle();
        expect(find.text('更多'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
