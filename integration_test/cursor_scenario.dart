import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/rdp/rdp_cursor.dart';
import 'package:lrdp/rdp/rdp_session.dart';

/// Shared real-wire scenario for Flutter tester and the Android FFI runtime.
Future<void> exerciseRdpCursor(
  RdpSession session,
  String pin, {
  Future<void> Function(int stage)? inspect,
}) async {
  Future<void> until(bool Function() ready, int stage) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    expect(
      ready(),
      isTrue,
      reason: 'Cursor stage $stage: ${session.state} ${session.error}',
    );
  }

  Future<List<int>> pixel(ui.Image image, int x, int y) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final offset = (y * image.width + x) * 4;
    return data!.buffer.asUint8List().sublist(offset, offset + 4);
  }

  await session.connect(password: '', acceptedFingerprint: pin);
  var previous = session.cursor;
  for (var stage = 0; stage <= 8; stage++) {
    await until(
      () =>
          !identical(session.cursor, previous) &&
          (stage != 0 || session.cursor.kind == RdpCursorKind.bitmap),
      stage,
    );
    final cursor = session.cursor;
    if (stage == 1 || stage == 5) {
      expect(
        cursor.kind,
        stage == 1 ? RdpCursorKind.hidden : RdpCursorKind.system,
      );
      expect(cursor.image, isNull);
      expect(cursor.inversion, isNull);
    } else {
      expect(cursor.kind, RdpCursorKind.bitmap);
      final side = stage >= 7
          ? 384
          : stage == 0 || stage == 2
          ? 8
          : 16;
      expect(cursor.image!.width, side);
      expect(cursor.image!.height, side);
      if (stage == 0 || stage == 2) {
        expect((cursor.hotX, cursor.hotY), (3, 5));
        expect(await pixel(cursor.image!, 0, 0), [100, 50, 20, 128]);
        expect(cursor.inversion, isNull);
      } else if (stage >= 7) {
        expect((cursor.hotX, cursor.hotY), (383, 383));
        expect(await pixel(cursor.image!, 0, 0), [0x22, 0x44, 0x66, 255]);
      } else {
        expect(await pixel(cursor.image!, 0, 0), [0, 0, 0, 255]);
        expect(await pixel(cursor.image!, 1, 0), [255, 255, 255, 255]);
        expect(await pixel(cursor.image!, 2, 0), [0, 0, 0, 0]);
        expect(await pixel(cursor.image!, 3, 0), [0, 0, 0, 0]);
        expect(await pixel(cursor.inversion!, 3, 0), [255, 255, 255, 255]);
        expect(await pixel(cursor.inversion!, 0, 0), [0, 0, 0, 0]);
      }
      if (stage == 4) {
        expect((cursor.x, cursor.y), (123, 77));
        expect(cursor.positionSerial, isNot(0));
        expect(
          identical(previous.image, cursor.image),
          isTrue,
          reason: 'A position-only PDU must reuse the decoded cursor image',
        );
      }
    }
    await inspect?.call(stage);
    previous = cursor;
    session.scan(0x1e, true);
    session.scan(0x1e, false);
  }
  await until(() => session.state == SessionState.closed, 9);
  expect(session.endReason, SessionEndReason.remote);
  expect(session.error, isNot(contains('解码失败')));
}
