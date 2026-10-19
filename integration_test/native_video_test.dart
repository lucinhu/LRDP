import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/native_video.dart';
import 'package:lrdp/rdp/rdp_cursor.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/remote_view_memory.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'real native texture pixels, XOR, zoom, pause, remount and cleanup',
    (tester) async {
      final control = Directory(Platform.environment['LRDP_VIDEO_CONTROL']!);
      final fallback =
          Platform.environment['LRDP_VIDEO_TEST_FAIL_UPLOAD'] == '1';
      final port = int.parse(Platform.environment['LRDP_VIDEO_PORT']!);
      final session = RdpSession(
        ConnectionProfile(
          id: 'texture',
          name: 'Private texture',
          host: '127.0.0.1',
          port: port,
          nla: false,
          clipboard: false,
        ),
        protocolDirectory: '${control.path}/protocol',
      );
      int frameCount() =>
          fallback ? session.decodedFrames : session.textureFrames;
      final focus = FocusNode();
      final transform = TransformationController();
      final active = ValueNotifier(true);
      final memory = RemoteSurfaceMemory();
      Future<void> until(bool Function() ready, String reason) async {
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (!ready() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(
          ready(),
          isTrue,
          reason: '$reason: ${session.state} ${session.error}',
        );
      }

      Widget scene() => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
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
      Future<void> stage(String name, List<int> rgb) async {
        await tester.pump();
        final rect = tester.getRect(find.byType(RemoteSurface));
        final ratio = tester.view.devicePixelRatio;
        final base = math.min(
          rect.width / session.desktopWidth,
          rect.height / session.desktopHeight,
        );
        final origin = Offset(
          (rect.width - session.desktopWidth * base) / 2,
          (rect.height - session.desktopHeight * base) / 2,
        );
        final zoom = transform.value.getMaxScaleOnAxis();
        final cursorScale = math.max(base, 1 / zoom);
        List<int> screen(Offset p) {
          final point =
              rect.topLeft + MatrixUtils.transformPoint(transform.value, p);
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
        };
        final tmp = File('${control.path}/stage.tmp');
        await tmp.writeAsString(jsonEncode(value));
        await tmp.rename('${control.path}/stage.json');
        final ack = File('${control.path}/$name.ack');
        await until(ack.existsSync, 'Host did not verify $name');
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
        final picture = recorder.endRecording();
        final image = picture.toImageSync(4, 4);
        picture.dispose();
        return image;
      }

      Future<Map<String, dynamic>> diagnostics() async => (await NativeVideo
          .channel
          .invokeMapMethod<String, dynamic>('diagnostics'))!;
      Future<void> clean() async {
        for (var i = 0; i < 100; i++) {
          final value = await diagnostics();
          if (value.entries
              .where(
                (e) =>
                    e.key != 'uploadFailures' && e.key != 'sharedPlaceholder',
              )
              .every((e) => e.value == 0)) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(await diagnostics(), everyPairZero);
      }

      try {
        await tester.pumpWidget(scene());
        await session.connect(password: '');
        await until(
          () => session.state == SessionState.certificateRequired,
          'Private certificate probe',
        );
        final pin = session.fingerprint;
        await session.connect(password: '', acceptedFingerprint: pin);
        if (fallback) {
          await until(
            () => session.image != null && session.textureId == null,
            'CPU fallback',
          );
          for (
            var i = 0;
            i < 300 && (await diagnostics())['uploadFailures'] == 0;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          expect((await diagnostics())['uploadFailures'], greaterThan(0));
          await clean();
          await tester.pump();
          expect(find.byType(RawImage), findsOneWidget);
        } else {
          await until(
            () => session.textureId != null && session.textureFrames > 0,
            'Native GL upload',
          );
          expect(find.byType(Texture), findsOneWidget);
          expect(find.byType(RawImage), findsNothing);
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
          hotX: 0,
          hotY: 0,
        );
        session.notifyListeners();
        await tester.pump();
        final first = frameCount();
        await stage('base', [24, 45, 40]);
        await until(() => frameCount() > first, 'Remote color update');
        await stage('updated', [138, 59, 193]);
        active.value = false;
        session.setVisible(false);
        await tester.pump();
        final hidden = frameCount();
        await stage('hidden', [138, 59, 193]);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(frameCount(), hidden);
        await stage('still-hidden', [138, 59, 193]);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(scene());
        active.value = true;
        session.setVisible(true);
        await tester.pump();
        await until(() => frameCount() > hidden, 'Resume latest frame');
        expect(session.textureId, id);
        await stage('resumed', [42, 132, 101]);
        transform.value = Matrix4.diagonal3Values(2, 2, 1)
          ..setTranslationRaw(-200, -100, 0);
        await tester.pump();
        await stage('zoomed', [42, 132, 101]);
        if (fallback) {
          expect(session.decodedFrames, greaterThan(decoded));
        } else {
          expect(
            session.decodedFrames,
            decoded,
            reason: 'No frame-byte decoding while texture is active',
          );
        }
        final decodedFinal = session.decodedFrames;
        await tester.pumpWidget(const SizedBox());
        await session.close();
        await clean();
        for (var i = 0; i < 3; i++) {
          await tester.pumpWidget(scene());
          final failures = (await diagnostics())['uploadFailures'] as int;
          await session.connect(password: '', acceptedFingerprint: pin);
          if (fallback) {
            await until(
              () => session.image != null && session.textureId == null,
              'Repeated CPU fallback',
            );
            for (
              var j = 0;
              j < 300 && (await diagnostics())['uploadFailures'] == failures;
              j++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            expect((await diagnostics())['uploadFailures'], failures + 1);
            expect((await diagnostics())['sharedPlaceholder'], 1);
            await clean();
            await tester.pump();
            expect(find.byType(RawImage), findsOneWidget);
          } else {
            await until(
              () => session.textureId != null && session.textureFrames > 0,
              'Repeated native connection',
            );
            expect((await diagnostics())['registered'], 1);
          }
          await tester.pumpWidget(const SizedBox());
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
        await tester.pumpWidget(const SizedBox());
        await session.close();
        session.dispose();
        focus.dispose();
        transform.dispose();
        active.dispose();
      }
    },
  );
}

final everyPairZero = predicate<Map<String, dynamic>>(
  (value) => value.entries
      .where((e) => e.key != 'uploadFailures' && e.key != 'sharedPlaceholder')
      .every((e) => e.value == 0),
  'all native render resources released',
);
