import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/native_video.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:path_provider/path_provider.dart';

/// Device acceptance of the pre-API30 renderer's idle path. A private 240 Hz
/// bitmap producer supplies real frames; no mocked platform channel is used.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Android native texture converges after producer silence', (
    tester,
  ) async {
    final control = await getApplicationSupportDirectory();
    final fixture =
        jsonDecode(
              await File('${control.path}/cpu-fixture.json').readAsString(),
            )
            as Map<String, dynamic>;
    final session = RdpSession(
      ConnectionProfile(
        id: 'android-cpu',
        name: 'Private CPU fixture',
        host: '127.0.0.1',
        port: fixture['port'] as int,
        width: 320,
        height: 240,
        automaticResolution: false,
        autoReconnect: false,
        clipboard: false,
        nla: false,
      ),
      protocolDirectory: '${control.path}/protocol',
    );
    final samples = <String, dynamic>{};
    final report = <String, dynamic>{'passed': false, 'samples': samples};
    int? texture;
    Future<void> save(String name, Object value) async {
      final tmp = File('${control.path}/$name.tmp');
      await tmp.writeAsString(jsonEncode(value));
      await tmp.rename('${control.path}/$name.json');
    }

    Future<void> until(bool Function() ready, String reason) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(
        ready(),
        isTrue,
        reason: '$reason: ${session.state} ${session.error}',
      );
    }

    Future<Map<String, dynamic>> status() async {
      final value = (await NativeVideo.channel.invokeMapMethod<String, dynamic>(
        'status',
        {'id': texture},
      ))!;
      expect(value['failed'], isFalse, reason: '$value');
      for (final key in [
        'uploads',
        'generation',
        'drawAttempts',
        'sizeChanges',
      ]) {
        expect(value[key], isA<int>(), reason: 'Missing native counter $key');
      }
      return value;
    }

    Future<Map<String, dynamic>> diagnostics() async => (await NativeVideo
        .channel
        .invokeMapMethod<String, dynamic>('diagnostics'))!;

    Future<void> stage(String name, [Map<String, dynamic>? extra]) async {
      await save('cpu-stage', {'stage': name, ...?extra});
      await until(
        File('${control.path}/cpu-$name.ack').existsSync,
        'Host did not acknowledge $name',
      );
    }

    Future<Map<String, dynamic>> sample(String name, Duration duration) async {
      final before = await status();
      final watch = Stopwatch()..start();
      await Future<void>.delayed(duration);
      final after = await status();
      watch.stop();
      final delta = <String, int>{
        for (final key in [
          'uploads',
          'generation',
          'drawAttempts',
          'sizeChanges',
        ])
          key: (after[key] as int) - (before[key] as int),
      };
      final value = <String, dynamic>{
        'before': before,
        'after': after,
        'delta': delta,
        'wall_seconds': watch.elapsedMicroseconds / 1000000,
        'uploads_per_second':
            delta['uploads']! * 1000000 / watch.elapsedMicroseconds,
      };
      samples[name] = value;
      return value;
    }

    void expectIdle(Map<String, dynamic> value) {
      final delta = value['delta'] as Map<String, int>;
      for (final key in [
        'uploads',
        'generation',
        'drawAttempts',
        'sizeChanges',
      ]) {
        expect(delta[key], 0, reason: 'Idle $key must converge: $value');
      }
    }

    Future<void> pixels(String name) async {
      await tester.pump();
      final rect = tester.getRect(find.byType(Texture));
      final ratio = tester.view.devicePixelRatio;
      List<double> screen(double x, double y) => [
        (rect.left + x * rect.width / 320) * ratio,
        (rect.top + y * rect.height / 240) * ratio,
      ];
      await stage(name, {
        'texture': texture,
        'status': await status(),
        'view': [
          tester.view.physicalSize.width,
          tester.view.physicalSize.height,
        ],
        'pixels': [
          {
            'point': screen(160.5, 120.5),
            'rgb': [117, 69, 128],
          },
          {
            'point': screen(.5, .5),
            'rgb': [177, 41, 17],
          },
          {
            'point': screen(319.5, 239.5),
            'rgb': [93, 59, 231],
          },
        ],
      });
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: ListenableBuilder(
                  listenable: session,
                  builder: (_, _) => session.textureId == null
                      ? const SizedBox()
                      : SizedBox(
                          width: 320,
                          height: 240,
                          child: Texture(
                            textureId: session.textureId!,
                            filterQuality: FilterQuality.none,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      );
      // The producer handles one peer. The host starts a fresh producer with the
      // same private certificate after this deliberately rejected TLS probe.
      await stage('probe-ready');
      await session.connect(password: '');
      await until(
        () => session.state == SessionState.certificateRequired,
        'Certificate probe',
      );
      final pin = session.fingerprint;
      expect(
        pin,
        fixture['pin'],
        reason: 'Probe must match the private TLS cert',
      );
      report['certificate_probe_pin'] = pin;
      await stage('certificate-probed');
      await session.connect(password: '', acceptedFingerprint: pin);
      await until(
        () =>
            session.state == SessionState.connected &&
            session.textureId != null &&
            session.textureFrames > 0,
        'Actual native texture upload',
      );
      texture = session.textureId;
      expect(session.desktopWidth, 320);
      expect(session.desktopHeight, 240);
      expect(
        session.decodedFrames,
        0,
        reason: 'Texture path must avoid Dart decode',
      );
      await tester.pump();
      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      report['native_texture'] = texture;
      for (final fps in [60, 30, 120]) {
        session.setFrameRate(fps);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final value = await sample(
          'streaming_$fps',
          const Duration(milliseconds: 500),
        );
        expect((value['delta'] as Map<String, int>)['uploads'], greaterThan(0));
        expect((value['delta'] as Map<String, int>)['sizeChanges'], 0);
        // Choreographer is display-limited. 120 requested on a 60 Hz emulator
        // does not imply 120 actual native uploads or screen presentations.
      }
      session.setFrameRate(30);
      session.scan(0x20, true);
      session.scan(0x20, false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await pixels('silent-pixels');
      expectIdle(await sample('silent_1s', const Duration(seconds: 1)));
      final quiet = await status();
      for (final fps in [120, 60, 30]) {
        session.setFrameRate(fps);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final changed = await status();
      samples['idle_fps_changes'] = {'before': quiet, 'after': changed};
      for (final key in [
        'uploads',
        'generation',
        'drawAttempts',
        'sizeChanges',
      ]) {
        expect(
          changed[key],
          quiet[key],
          reason: 'Changing FPS redrew static $key',
        );
      }
      expectIdle(await sample('idle_after_fps_1s', const Duration(seconds: 1)));
      final beforeReset = await status();
      await NativeVideo.channel.invokeMethod<void>('testRecreateSurface', {
        'id': texture,
      });
      await until(
        () => session.textureFrames > (beforeReset['uploads'] as int),
        'Unchanged frame redraw after surface recreation',
      );
      final afterReset = await status();
      expect(
        afterReset['drawAttempts'],
        greaterThan(beforeReset['drawAttempts'] as int),
      );
      // The test hook intentionally changes the size away and back.
      expect(
        afterReset['sizeChanges'],
        (beforeReset['sizeChanges'] as int) + 2,
      );
      samples['surface_recreated'] = {
        'before': beforeReset,
        'after': afterReset,
      };
      await pixels('recreated-pixels');
      expectIdle(await sample('recreated_idle_1s', const Duration(seconds: 1)));
      session.setVisible(false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expectIdle(await sample('hidden_1s', const Duration(seconds: 1)));
      final beforeResume = await status();
      session.setVisible(true);
      await until(
        () => session.textureFrames > (beforeResume['uploads'] as int),
        'Resume redraw of retained static frame',
      );
      expect(session.textureId, texture);
      samples['resumed'] = {'before': beforeResume, 'after': await status()};
      await pixels('resumed-pixels');
      expectIdle(await sample('resumed_idle_1s', const Duration(seconds: 1)));
      expect(session.decodedFrames, 0);
      report['decoded_frames'] = session.decodedFrames;
      report['final_status'] = await status();
      session.scan(0x1e, true);
      session.scan(0x1e, false);
      await stage('input-ack');
      await tester.pumpWidget(const SizedBox());
      await session.close();
      Map<String, dynamic> resources = await diagnostics();
      bool released() => resources.entries
          .where((e) => e.key != 'uploadFailures' && e.key != 'presentedFrames')
          .every((e) => e.value == 0);
      for (var i = 0; i < 100 && !released(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        resources = await diagnostics();
      }
      expect(
        released(),
        isTrue,
        reason: 'Native render resources leaked: $resources',
      );
      report['stopped_diagnostics'] = resources;
      report['passed'] = true;
    } catch (error, stack) {
      report['error'] = '$error';
      report['stack'] = '$stack';
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox());
      await session.close();
      session.dispose();
      await save('cpu-result', report);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
