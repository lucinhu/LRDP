import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/theme.dart';
import 'package:lrdp/ui/workspace_screen.dart';

// Only the host's private emulator runs this entrypoint. Gestures under test
// come through Android InputManager, not WidgetTester pointer injection.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.shouldPropagateDevicePointerEvents = true;
  late Directory support;
  var deviceEvents = 0, testEvents = 0;
  final pointerTrace = <Map<String, Object>>[];
  final sessions = <RdpSession>[];

  Map<String, dynamic> geometry(WidgetTester tester) {
    final finder = find.byType(RemoteSurface);
    final data = <String, dynamic>{
      'device_events': deviceEvents,
      'test_events': testEvents,
      'sessions': sessions.length,
      'connected': sessions.isNotEmpty && sessions.single.isActive,
      'lifecycle': binding.lifecycleState?.name,
    };
    if (finder.evaluate().isEmpty) return data;
    final surface = tester.widget<RemoteSurface>(finder);
    if (!surface.session.hasVideo) return data;
    final rect = tester.getRect(finder);
    final ratio = tester.view.devicePixelRatio;
    final back = tester.getCenter(find.byTooltip('返回电脑列表（保持连接）'));
    return {
      ...data,
      'bounds': [
        rect.left * ratio,
        rect.top * ratio,
        rect.width * ratio,
        rect.height * ratio,
      ],
      'back': [back.dx * ratio, back.dy * ratio],
      'ratio': ratio,
      'matrix': surface.transform.value.storage.toList(),
      'remote': [surface.session.desktopWidth, surface.session.desktopHeight],
      'native_texture': surface.session.textureId != null,
      'texture_uploads': surface.session.textureFrames,
      'dart_decodes': surface.session.decodedFrames,
      'trackpad': surface.trackpad,
      'pan': surface.pan,
      'server_cursor': [
        surface.session.cursor.x,
        surface.session.cursor.y,
        surface.session.cursor.positionSerial,
      ],
      'stored_pointer': surface.memory?.viewport?.pointer == null
          ? null
          : [
              surface.memory!.viewport!.pointer!.dx,
              surface.memory!.viewport!.pointer!.dy,
              surface.memory!.viewport!.serverPositionSerial,
            ],
      'pointer_trace': pointerTrace.toList(),
      'sent_mouse': (surface.session as _ObservedSession).mouseTrace.toList(),
    };
  }

  Future<void> stage(WidgetTester tester, String name) async {
    final ack = File('${support.path}/lrdp-gesture-$name.ack');
    if (await ack.exists()) await ack.delete();
    await File('${support.path}/lrdp-gesture-stage.json').writeAsString(
      jsonEncode({'stage': name, ...geometry(tester)}),
      flush: true,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 100));
    while (!await ack.exists() && DateTime.now().isBefore(deadline)) {
      final live = File('${support.path}/lrdp-gesture-live.tmp');
      await live.writeAsString(
        jsonEncode({'stage': name, ...geometry(tester)}),
      );
      await live.rename('${support.path}/lrdp-gesture-live.json');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(await ack.exists(), isTrue, reason: 'Host did not finish $name');
  }

  Future<void> until(bool Function() ready, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(ready(), isTrue, reason: reason);
  }

  Future<void> scenario(WidgetTester tester, String name) async {
    await stage(tester, 'start-$name');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await stage(tester, 'end-$name');
  }

  Future<void> fit(WidgetTester tester) async {
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('适应屏幕'));
    await tester.pumpAndSettle();
  }

  void checkBounds(WidgetTester tester) {
    final surface = tester.widget<RemoteSurface>(find.byType(RemoteSurface));
    final size = tester.getSize(find.byType(RemoteSurface));
    final width = surface.session.desktopWidth,
        height = surface.session.desktopHeight;
    final base = math.min(size.width / width, size.height / height);
    final matrix = surface.transform.value;
    final zoom = matrix.getMaxScaleOnAxis();
    for (final axis in [
      (size.width, width * base, matrix.storage[12]),
      (size.height, height * base, matrix.storage[13]),
    ]) {
      final extent = axis.$2 * zoom;
      final origin = (axis.$1 - axis.$2) / 2 * zoom + axis.$3;
      if (extent <= axis.$1) {
        expect(origin, closeTo((axis.$1 - extent) / 2, 1));
      } else {
        expect(origin, lessThanOrEqualTo(1));
        expect(origin + extent, greaterThanOrEqualTo(axis.$1 - 1));
      }
    }
  }

  testWidgets('Android OS gestures reach the actual RDP desktop', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    support = await getApplicationSupportDirectory();
    final config = File('${support.path}/lrdp-gesture-config.json');
    if (await config.exists()) await config.delete();
    await stage(tester, 'config');
    final data =
        jsonDecode(await config.readAsString()) as Map<String, dynamic>;
    SharedPreferences.setMockInitialValues({});
    final store = ProfileStore(await SharedPreferences.getInstance());
    final protocol = await Directory(
      '${support.path}/lrdp-gesture-protocol',
    ).create();
    final profile = ConnectionProfile(
      id: 'private-os-gestures',
      name: '手机手势回环测试',
      host: '127.0.0.1',
      port: data['port'] as int,
      width: 2560,
      height: 1600,
      username: 'test',
      rememberPassword: true,
      nla: false,
      clipboard: false,
      autoReconnect: false,
    );
    void pointer(PointerEvent event) {
      if (binding.pointerEventSource.name == 'device') {
        deviceEvents++;
        pointerTrace.add({
          'type': event.runtimeType.toString(),
          'kind': event.kind.name,
          'device': event.device,
          'pointer': event.pointer,
          'x': event.position.dx,
          'y': event.position.dy,
          'dx': event.delta.dx,
          'dy': event.delta.dy,
        });
        if (pointerTrace.length > 40) pointerTrace.removeAt(0);
      } else {
        testEvents++;
      }
    }

    try {
      await store.save(profile, password: 'private-gesture-fixture');
      await store.trust(profile, data['pin'] as String);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Listener(
            onPointerDown: pointer,
            onPointerMove: pointer,
            onPointerUp: pointer,
            onPointerCancel: pointer,
            onPointerHover: pointer,
            child: WorkspaceScreen(
              store: store,
              protocolDirectory: protocol.path,
              sessionFactory: (profile, directory) {
                final session = _ObservedSession(
                  profile,
                  protocolDirectory: directory,
                );
                sessions.add(session);
                return session;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(profile.name));
      await until(
        () =>
            sessions.isNotEmpty &&
            sessions.single.hasVideo &&
            sessions.single.textureFrames > 0,
        'No actual RDP frame',
      );
      await tester.pumpAndSettle();
      final session = sessions.single;
      expect(session.desktopWidth, 2560);
      expect(session.desktopHeight, 1600);
      expect(session.textureId, isNotNull);
      // External textures must be sampled from the OS compositor. The host
      // checks remote pixel (100,100) rather than reading a Dart image copy.
      await stage(tester, 'frame-color');
      expect(
        tester.widget<RemoteSurface>(find.byType(RemoteSurface)).trackpad,
        isTrue,
      );
      await scenario(tester, 'tap-trackpad');
      await tester.tap(find.text('触控板'));
      await tester.pumpAndSettle();
      await scenario(tester, 'tap-direct');
      await tester.tap(find.text('触屏'));
      await tester.pumpAndSettle();
      for (final name in [
        'pinch',
        'follow',
        'right-tap',
        'long-press',
        'scroll-down',
        'scroll-up',
        'scroll-left',
        'scroll-right',
        'drag',
        'cancel',
        'background',
        'bounds',
      ]) {
        await scenario(tester, name);
        if (name == 'drag') await scenario(tester, 'tap-after-drag');
        expect(session.state, SessionState.connected);
        checkBounds(tester);
      }
      await fit(tester);
      await scenario(tester, 'pinch-hardware');
      await scenario(tester, 'hardware-edge');
      await scenario(tester, 'hardware-stop');
      await scenario(tester, 'rotate');
      checkBounds(tester);
      await scenario(tester, 'portrait');
      checkBounds(tester);
      await scenario(tester, 'inactive');
      expect(find.byType(RemoteSurface), findsNothing);
      await tester.tap(find.text(profile.name));
      await tester.pumpAndSettle();
      expect(sessions, hasLength(1));
      expect(session.state, SessionState.connected);
      await stage(tester, 'returned');
      await tester.tap(find.text('触控板'));
      await tester.tap(find.text('缩放'));
      await tester.pumpAndSettle();
      await stage(tester, 'start-mode-return');
      expect(find.byType(RemoteSurface), findsNothing);
      await tester.tap(find.text(profile.name));
      await tester.pumpAndSettle();
      expect(sessions, hasLength(1));
      expect(session.state, SessionState.connected);
      checkBounds(tester);
      await stage(tester, 'end-mode-return');
      expect(deviceEvents, greaterThan(100));
      await session.close();
      await stage(tester, 'closed');
      binding.reportData = {
        'device_events': deviceEvents,
        'sessions': sessions.length,
        'scope':
            'Android InputManager -> production Workspace/RemoteSurface -> actual RDP -> private X11 events',
        'physical_device': false,
      };
    } finally {
      await tester.pumpWidget(const SizedBox());
      for (final session in sessions) {
        await session.close();
        session.dispose();
      }
      await store.remove(profile);
      store.dispose();
      if (await protocol.exists()) await protocol.delete(recursive: true);
      if (await config.exists()) await config.delete();
    }
  });
}

// Passive diagnostics; the production RdpSession still owns the real worker.
class _ObservedSession extends RdpSession {
  _ObservedSession(super.profile, {super.protocolDirectory});
  final mouseTrace = <List<int>>[];
  @override
  void mouse(int flags, int x, int y) {
    mouseTrace.add([flags, x, y]);
    if (mouseTrace.length > 12) mouseTrace.removeAt(0);
    super.mouse(flags, x, y);
  }
}
