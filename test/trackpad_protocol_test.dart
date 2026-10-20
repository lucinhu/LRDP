import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/remote_surface.dart';

void main() {
  testWidgets('desktop gesture streams deliver exact wheel PDUs over TLS', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('lrdp-trackpad-');
    final session = RdpSession(
      ConnectionProfile(
        id: 'trackpad',
        name: 'Private trackpad fixture',
        host: '127.0.0.1',
        port: int.parse(Platform.environment['LRDP_TRACKPAD_PORT']!),
        nla: false,
        automaticResolution: false,
      ),
      protocolDirectory: directory.path,
    );
    final focus = FocusNode();
    final transform = TransformationController();
    final active = ValueNotifier(true);
    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      expect(condition(), isTrue, reason: '${session.state}: ${session.error}');
    }

    try {
      await tester.runAsync(
        () => session.connect(
          password: '',
          acceptedFingerprint: Platform.environment['LRDP_TRACKPAD_PIN']!,
        ),
      );
      await until(
        () => session.state == SessionState.connected && session.hasVideo,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (context, enabled, child) => Focus(
                focusNode: focus,
                child: RemoteSurface(
                  session: session,
                  focus: focus,
                  transform: transform,
                  trackpad: false,
                  pan: false,
                  active: enabled,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final pointer = TestPointer(61, PointerDeviceKind.trackpad);
      const center = Offset(200, 200);
      for (final direction in [1.0, -1.0]) {
        await tester.sendEventToBinding(pointer.panZoomStart(center));
        for (var i = 1; i <= 48; i++) {
          await tester.sendEventToBinding(
            pointer.panZoomUpdate(
              center,
              pan: Offset(i * direction, i * direction),
            ),
          );
        }
        await tester.sendEventToBinding(pointer.panZoomEnd());
      }
      await tester.sendEventToBinding(pointer.panZoomStart(center));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(center, scale: 1.5, pan: const Offset(40, 30)),
      );
      await tester.sendEventToBinding(pointer.panZoomEnd());
      expect(transform.value.getMaxScaleOnAxis(), closeTo(1.5, .001));
      await tester.sendEventToBinding(pointer.panZoomStart(center));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(center, pan: const Offset(0, 20)),
      );
      active.value = false;
      await tester.pump();
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(center, pan: const Offset(0, 120)),
      );
      await tester.sendEventToBinding(pointer.panZoomEnd());
      active.value = true;
      await tester.pump();
      for (final delta in [const Offset(0, 40), const Offset(40, 0)]) {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: center, scrollDelta: delta),
        );
      }
      await until(() => session.cursor.x == 77 && session.cursor.y == 100);
      session.chord([0x1e]);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.close);
      session.dispose();
      focus.dispose();
      transform.dispose();
      active.dispose();
      directory.deleteSync(recursive: true);
    }
  }, skip: Platform.environment['LRDP_TRACKPAD_PORT'] == null);
}
