import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/native_video.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:path_provider/path_provider.dart';

/// Real private TLS/RDPGFX AVC420. Software MediaCodec injection, when requested,
/// is a debug-only bridge test and never establishes hardware acceleration.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Android AVC420 backend, pixels and resource lifetime', (
    tester,
  ) async {
    final control = await getApplicationSupportDirectory();
    final fixture =
        jsonDecode(
              await File('${control.path}/h264-fixture.json').readAsString(),
            )
            as Map<String, dynamic>;
    final softwareTest = fixture['mode'] == 'software-codec';
    final report = <String, dynamic>{
      'passed': false,
      'mode': fixture['mode'],
      'hardware_acceptance': false,
      'forcedSoftwareBridge': softwareTest,
    };
    final session = RdpSession(
      ConnectionProfile(
        id: 'android-h264',
        name: 'Private AVC420 fixture',
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
    final history = <int>[];
    void backendChanged() {
      if (history.isEmpty || history.last != session.decoderBackend) {
        history.add(session.decoderBackend);
      }
    }

    session.addListener(backendChanged);
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

    Future<Map<String, dynamic>> query(
      String method, [
      Map<String, dynamic>? arguments,
    ]) async => (await NativeVideo.channel.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    ))!;

    Future<void> stage(String name, [Map<String, dynamic>? extra]) async {
      await save('h264-stage', {'stage': name, ...?extra});
      if (name == 'color-stream') {
        final streamWatch = Stopwatch()..start();
        final samples = <Map<String, dynamic>>[];
        report['color_stream_samples'] = samples;
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!File('${control.path}/h264-$name.ack').existsSync() &&
            DateTime.now().isBefore(deadline)) {
          final live = <String, dynamic>{
            'elapsed_seconds': streamWatch.elapsedMicroseconds / 1000000,
            'backend': session.decoderBackend,
            'backend_history': List<int>.of(history),
            'features': session.features,
            'texture_frames': session.textureFrames,
            'decoded_frames': session.decodedFrames,
            'session_state': session.state.name,
            'error': session.error,
            'status': await query('status', {'id': session.textureId}),
            'decoder': await query('h264Diagnostics'),
            'render_diagnostics': await query('diagnostics'),
          };
          samples.add(live);
          report['last_color_stream_state'] = live;
          await save('h264-live', {...live, 'samples': samples});
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      await until(
        File('${control.path}/h264-$name.ack').existsSync,
        'Host did not acknowledge $name',
      );
    }

    int? texture;
    Future<Map<String, dynamic>> status() async {
      final value = await query('status', {'id': texture});
      expect(value['failed'], isFalse, reason: '$value');
      return value;
    }

    try {
      final caps = await query('h264Capabilities');
      report['capabilities'] = caps;
      expect(caps['api'], greaterThanOrEqualTo(24));
      final hardware = (caps['hardwareCandidates'] as List).cast<Map>();
      final software = (caps['softwareCandidates'] as List).cast<Map>();
      // CodecInfo may advertise a virtual goldfish codec as hardware. Validate
      // its strict flags without treating an emulator as physical acceleration.
      for (final codec in hardware) {
        expect(codec['isHardwareAccelerated'], isTrue);
        expect(codec['isSoftwareOnly'], isFalse);
      }
      for (final codec in software) {
        expect(codec['isHardwareAccelerated'], isFalse);
        expect(codec['isSoftwareOnly'], isTrue);
        expect(
          hardware.map((value) => value['name']),
          isNot(contains(codec['name'])),
        );
      }
      report['emulator_only'] = true;
      report['physical_device_tested'] = false;
      expect(session.decoderBackend, 0);
      if (softwareTest) {
        expect(caps['api'], greaterThanOrEqualTo(29));
        expect(caps['testHooksEnabled'], isTrue);
        expect(caps['softwareCandidates'], isNotEmpty);
        final requested = fixture['software_component'] as String?;
        final matches = software.where((codec) => codec['name'] == requested);
        if (requested != null) {
          expect(
            matches,
            hasLength(1),
            reason: 'Exact software candidate required',
          );
        }
        final codec = requested == null ? software.first : matches.single;
        expect(codec['isHardwareAccelerated'], isFalse);
        expect(codec['isSoftwareOnly'], isTrue);
        report['test_codec'] = codec['name'];
        await NativeVideo.channel.invokeMethod<void>('testH264SoftwareCodec', {
          'name': codec['name'],
        });
      }
      report['decoder_before'] = await query('h264Diagnostics');
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
      await stage('probe-ready');
      await session.connect(password: '');
      await until(
        () => session.state == SessionState.certificateRequired,
        'Private TLS certificate probe',
      );
      final pin = session.fingerprint;
      expect(pin, fixture['pin']);
      report['certificate_probe_pin'] = pin;
      await stage('certificate-probed');
      await session.connect(password: '', acceptedFingerprint: pin);
      await until(
        () =>
            session.state == SessionState.connected &&
            session.textureId != null &&
            session.textureFrames > 0,
        'Actual native texture',
      );
      texture = session.textureId;
      await tester.pump();
      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      final rect = tester.getRect(find.byType(Texture));
      final ratio = tester.view.devicePixelRatio;
      // The host observes all three timed color groups and checks every screen
      // RGB pixel inside this rectangle against the FFmpeg decoded reference.
      await stage('color-stream', {
        'texture': texture,
        'rect': [
          rect.left,
          rect.top,
          rect.right,
          rect.bottom,
        ].map((v) => v * ratio).toList(),
        'view': [
          tester.view.physicalSize.width,
          tester.view.physicalSize.height,
        ],
      });
      await until(
        () => session.hasDecodedAvc && session.decoderBackend != 0,
        'Successfully decoded AVC420',
      );
      expect(session.desktopWidth, 320);
      expect(session.desktopHeight, 240);
      expect(
        session.decodedFrames,
        0,
        reason: 'Native texture avoids Dart image decoding',
      );
      if (softwareTest) {
        expect(session.decoderBackend, 4);
      } else if ((caps['api'] as int) < 29 || hardware.isEmpty) {
        expect(session.decoderBackend, 1);
        expect(history, isNot(contains(4)));
      } else {
        expect(session.decoderBackend, isIn([1, 4]));
      }
      // Host has observed the final AU send; allow its presentation callback to
      // finish before measuring the separate one-second silent interval.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final decoder = await query('h264Diagnostics');
      report['decoder_after_frames'] = decoder;
      final initialDecoder = report['decoder_before'] as Map<String, dynamic>;
      final javaFrames =
          (decoder['decodedFrames'] as int) -
          (initialDecoder['decodedFrames'] as int);
      report['java_frames'] = javaFrames;
      report['backend_history'] = history;
      report['virtualCodec'] = decoder['selectedCodec'];
      if (softwareTest) {
        expect(javaFrames, 9);
        expect(decoder['testSoftwareCodec'], isTrue);
        expect(decoder['selectedCodec'], report['test_codec']);
      } else {
        expect(decoder['testSoftwareCodec'], isFalse);
        if (session.decoderBackend == 4) {
          expect(javaFrames, 9);
          expect(
            hardware.map((codec) => codec['name']),
            contains(decoder['selectedCodec']),
          );
        } else if ((caps['api'] as int) < 29 || hardware.isEmpty) {
          expect(javaFrames, 0);
        } else {
          // A strictly eligible virtual codec can still fail at runtime. CPU
          // fallback remains valid; preserve attempts, frames and history.
          expect(javaFrames, inInclusiveRange(0, 9));
          report['eligible_codec_cpu_fallback'] = true;
          if (javaFrames > 0) {
            expect(
              hardware.map((codec) => codec['name']),
              contains(decoder['selectedCodec']),
            );
          }
        }
      }
      final before = await status();
      await Future<void>.delayed(const Duration(seconds: 1));
      final after = await status();
      for (final key in [
        'generation',
        'uploads',
        'drawAttempts',
        'sizeChanges',
      ]) {
        expect(
          after[key],
          before[key],
          reason: 'Silent final AVC420 frame redrew: $key',
        );
      }
      report.addAll({
        'native_texture': texture,
        'decoded_frames': session.decodedFrames,
        'features': session.features,
        'backend': session.decoderBackend,
        'backend_history': history,
        'silent_before': before,
        'silent_after_1s': after,
      });
      await stage('silent-pixels', {
        'rect': [
          rect.left,
          rect.top,
          rect.right,
          rect.bottom,
        ].map((v) => v * ratio).toList(),
      });
      session.scan(0x1e, true);
      session.scan(0x1e, false);
      await stage('input-ack');
      await tester.pumpWidget(const SizedBox());
      final watch = Stopwatch()..start();
      await session.close();
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(3000));
      report['stop_seconds'] = watch.elapsedMicroseconds / 1000000;
      var resources = await query('diagnostics');
      var stoppedDecoder = await query('h264Diagnostics');
      bool released() =>
          resources.entries.every(
            (entry) =>
                entry.key == 'uploadFailures' ||
                entry.key == 'presentedFrames' ||
                entry.value == 0,
          ) &&
          stoppedDecoder['activeDecoders'] == 0 &&
          stoppedDecoder['activeImages'] == 0;
      final cleanupDeadline = DateTime.now().add(const Duration(seconds: 3));
      while (!released() && DateTime.now().isBefore(cleanupDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        resources = await query('diagnostics');
        stoppedDecoder = await query('h264Diagnostics');
      }
      for (final entry in resources.entries) {
        if (entry.key != 'uploadFailures' && entry.key != 'presentedFrames') {
          expect(entry.value, 0, reason: 'Render resource leaked: $entry');
        }
      }
      expect(stoppedDecoder['activeDecoders'], 0);
      expect(stoppedDecoder['activeImages'], 0);
      report['stopped_diagnostics'] = resources;
      report['stopped_decoder_diagnostics'] = stoppedDecoder;
      await stage('stopped');
      report['passed'] = true;
    } catch (error, stack) {
      report['error'] = '$error';
      report['stack'] = '$stack';
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox());
      await session.close();
      session.removeListener(backendChanged);
      session.dispose();
      try {
        if (softwareTest) {
          await NativeVideo.channel.invokeMethod<void>(
            'testH264SoftwareCodec',
            {'name': null},
          );
        }
      } finally {
        await save('h264-result', report);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
