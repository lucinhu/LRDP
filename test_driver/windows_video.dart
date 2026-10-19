import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/native_video.dart';
import 'package:lrdp/rdp/rdp_cursor.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/remote_view_memory.dart';

// Standalone acceptance entrypoint for the real Windows engine under Wine.
// The production plugin and RdpSession are used; no integration-test plugin.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final control = Directory(Platform.environment['LRDP_VIDEO_CONTROL']!);
  try {
    await exercise(control);
  } catch (error, stack) {
    await File('${control.path}/result.json').writeAsString(
      jsonEncode({'passed': false, 'error': '$error', 'stack': '$stack'}),
    );
  } finally {
    await File('${control.path}/done').writeAsString('done');
  }
}

void check(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<void> exercise(Directory control) async {
  final fallback = Platform.environment['LRDP_VIDEO_TEST_FAIL_UPLOAD'] == '1';
  final session = RdpSession(
    ConnectionProfile(
      id: 'windows-texture',
      name: 'Private Windows texture',
      host: '127.0.0.1',
      port: int.parse(Platform.environment['LRDP_VIDEO_PORT']!),
      nla: false,
      clipboard: false,
      fileTransfer: false,
    ),
    protocolDirectory: '${control.path}/protocol',
  );
  final focus = FocusNode();
  final transform = TransformationController();
  final active = ValueNotifier(true);
  final memory = RemoteSurfaceMemory();
  final surface = GlobalKey();
  int frameCount() => fallback ? session.decodedFrames : session.textureFrames;
  Future<void> until(bool Function() ready, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    check(ready(), '$reason: ${session.state} ${session.error}');
  }

  Widget scene() => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          key: surface,
          width: 800,
          height: 600,
          child: ListenableBuilder(
            listenable: Listenable.merge([session, active]),
            builder: (_, _) => session.hasVideo
                ? Focus(
                    focusNode: focus,
                    child: RemoteSurface(
                      session: session,
                      focus: focus,
                      transform: transform,
                      trackpad: true,
                      pan: false,
                      active: active.value,
                      memory: memory,
                    ),
                  )
                : const SizedBox(),
          ),
        ),
      ),
    ),
  );
  Future<Map<String, dynamic>> diagnostics() async => (await NativeVideo.channel
      .invokeMapMethod<String, dynamic>('diagnostics'))!;
  Future<void> clean() async {
    for (var i = 0; i < 200; i++) {
      final values = await diagnostics();
      if (values.entries
          .where((e) => e.key != 'uploadFailures')
          .every((e) => e.value == 0)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    throw StateError('Native resources still retained: ${await diagnostics()}');
  }

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> stage(String name, List<int> rgb) async {
    await settle();
    final box = surface.currentContext!.findRenderObject()! as RenderBox;
    final originInView = box.localToGlobal(Offset.zero);
    final ratio = View.of(surface.currentContext!).devicePixelRatio;
    final base = math.min(
      box.size.width / session.desktopWidth,
      box.size.height / session.desktopHeight,
    );
    final origin = Offset(
      (box.size.width - session.desktopWidth * base) / 2,
      (box.size.height - session.desktopHeight * base) / 2,
    );
    final zoom = transform.value.getMaxScaleOnAxis();
    final cursorScale = math.max(base, 1 / zoom);
    List<int> screen(Offset p) {
      final point =
          originInView + MatrixUtils.transformPoint(transform.value, p);
      return [(point.dx * ratio).floor(), (point.dy * ratio).floor()];
    }

    final value = {
      'stage': name,
      'rgb': rgb,
      'texture': session.textureId,
      'uploads': session.textureFrames,
      'decoded': session.decodedFrames,
      'background': screen(origin + const Offset(500, 400) * base),
      'cursor': [
        for (var i = 0; i < 4; i++)
          screen(
            origin +
                const Offset(200, 200) * base +
                Offset((i + .5) * cursorScale, .5 * cursorScale),
          ),
      ],
      if (name != 'zoomed')
        'markers': [
          screen(origin + const Offset(64, 64) * base),
          screen(origin + const Offset(1216, 736) * base),
        ],
    };
    final temporary = File('${control.path}/stage.tmp');
    await temporary.writeAsString(jsonEncode(value));
    await temporary.rename('${control.path}/stage.json');
    await until(
      File('${control.path}/$name.ack').existsSync,
      'Host did not verify $name',
    );
  }

  ui.Image cursorImage(bool inversion) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    if (inversion) {
      canvas.drawRect(
        const Rect.fromLTWH(3, 0, 1, 4),
        Paint()..color = Colors.white,
      );
    } else {
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 1, 4),
        Paint()..color = Colors.black,
      );
      canvas.drawRect(
        const Rect.fromLTWH(1, 0, 1, 4),
        Paint()..color = Colors.white,
      );
    }
    return recorder.endRecording().toImageSync(4, 4);
  }

  try {
    runApp(scene());
    await session.connect(password: '');
    await until(
      () => session.state == SessionState.certificateRequired,
      'Private certificate probe',
    );
    final pin = session.fingerprint;
    await session.connect(password: '', acceptedFingerprint: pin);
    await until(
      () => fallback
          ? session.image != null && session.textureId == null
          : session.textureId != null && session.textureFrames > 0,
      'First Windows frame',
    );
    if (fallback) {
      check((await diagnostics())['uploadFailures'] == 1, 'Injected failure');
      await clean();
    }
    final id = session.textureId, decoded = session.decodedFrames;
    session.cursor.image?.dispose();
    session.cursor.inversion?.dispose();
    session.cursor = RdpCursor(
      kind: RdpCursorKind.bitmap,
      image: cursorImage(false),
      inversion: cursorImage(true),
      x: 200,
      y: 200,
      positionSerial: 999,
    );
    session.notifyListeners();
    final first = frameCount();
    await stage('base', [24, 45, 40]);
    await until(() => frameCount() > first, 'Remote color update');
    await stage('updated', [138, 59, 193]);
    active.value = false;
    session.setVisible(false);
    await settle();
    final hidden = frameCount();
    await stage('hidden', [138, 59, 193]);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    check(frameCount() == hidden, 'Hidden renderer must be frozen');
    await stage('still-hidden', [138, 59, 193]);
    runApp(const SizedBox());
    await settle();
    runApp(scene());
    active.value = true;
    session.setVisible(true);
    await until(() => frameCount() > hidden, 'Resume latest frame');
    check(session.textureId == id, 'Resume must preserve texture');
    await stage('resumed', [42, 132, 101]);
    transform.value = Matrix4.diagonal3Values(2, 2, 1)
      ..setTranslationRaw(-200, -100, 0);
    await stage('zoomed', [42, 132, 101]);
    check(
      fallback
          ? session.decodedFrames > decoded
          : session.decodedFrames == decoded,
      'Native textures must not decode frame bytes in Dart',
    );
    final decodedFinal = session.decodedFrames;
    runApp(const SizedBox());
    await settle();
    await session.close();
    await clean();
    for (var i = 0; i < 3; i++) {
      runApp(scene());
      final failures = (await diagnostics())['uploadFailures'] as int;
      await session.connect(password: '', acceptedFingerprint: pin);
      await until(
        () => fallback
            ? session.image != null && session.textureId == null
            : session.textureId != null && session.textureFrames > 0,
        'Repeated Windows connection',
      );
      if (fallback) {
        check(
          (await diagnostics())['uploadFailures'] == failures + 1,
          'Each failed connection must use CPU fallback',
        );
      }
      runApp(const SizedBox());
      await settle();
      await session.close();
      await clean();
    }
    await File('${control.path}/result.json').writeAsString(
      jsonEncode({
        'passed': true,
        'native_texture': !fallback,
        'decoded_frames_initial': decoded,
        'decoded_frames_final': decodedFinal,
        'reconnections': 3,
        'diagnostics': await diagnostics(),
      }),
    );
  } finally {
    runApp(const SizedBox());
    await settle();
    await session.close();
    session.dispose();
    focus.dispose();
    transform.dispose();
    active.dispose();
  }
}
