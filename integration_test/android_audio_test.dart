import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/workspace_screen.dart';
import 'package:lrdp/ui/theme.dart';

// Private emulator entrypoint. Real WorkspaceScreen, native focus handler,
// Keystore and RDP worker; only disposable local services and test credentials.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  late Directory support;
  Future<void> stage(String name) async {
    final ack = File('${support.path}/lrdp-audio-$name.ack');
    if (await ack.exists()) await ack.delete();
    await File(
      '${support.path}/lrdp-audio-stage',
    ).writeAsString(name, flush: true);
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (!await ack.exists() && DateTime.now().isBefore(deadline)) {
      // Home and native focus actions can suspend vsync. Do not await a frame.
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      await ack.exists(),
      isTrue,
      reason: 'Host did not finish audio $name',
    );
  }

  Future<void> until(bool Function() ready, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(ready(), isTrue, reason: reason);
  }

  testWidgets('Android Workspace audio playback, background, focus and release', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    support = await getApplicationSupportDirectory();
    final config = File('${support.path}/lrdp-audio-config.json');
    if (await config.exists()) await config.delete();
    await stage('config');
    final data =
        jsonDecode(await config.readAsString()) as Map<String, dynamic>;
    SharedPreferences.setMockInitialValues({});
    final store = ProfileStore(await SharedPreferences.getInstance());
    final protocol = await Directory(
      '${support.path}/lrdp-audio-protocol',
    ).create(recursive: true);
    final sessions = <RdpSession>[];
    final profiles = [
      for (var i = 0; i < 2; i++)
        ConnectionProfile(
          id: 'audio-test-$i',
          name: '声音回环测试 ${i + 1}',
          host: '127.0.0.1',
          port: (data['ports'] as List)[i] as int,
          username: 'test',
          rememberPassword: true,
          nla: false,
          audio: true,
          clipboard: false,
          autoReconnect: false,
        ),
    ];
    try {
      for (final profile in profiles) {
        await store.save(profile, password: 'private-audio-fixture');
        await store.trust(profile, data['pin'] as String);
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: WorkspaceScreen(
            store: store,
            protocolDirectory: protocol.path,
            sessionFactory: (profile, directory) {
              final session = RdpSession(profile, protocolDirectory: directory);
              sessions.add(session);
              return session;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        await stage('before-$i');
        await tester.tap(find.text(profiles[i].name));
        await until(
          () =>
              sessions.length == i + 1 &&
              sessions.last.audioStatus == 'playing',
          'Initial RDPSND device: ${sessions.map((s) => '${s.state}/${s.audioStatus}/${s.error}')}',
        );
        final session = sessions.last;
        expect(session.state, SessionState.connected, reason: session.error);
        await stage('playing-$i');
        await stage('background-$i');
        await until(
          () => session.audioStatus == 'paused',
          'Background audio device was not closed',
        );
        expect(session.state, SessionState.connected);
        await stage('paused-$i');
        await stage('foreground-$i');
        await until(
          () => session.audioStatus == 'playing',
          'Foreground did not resume playback',
        );
        await stage('resumed-$i');
        if (i == 0) {
          for (final name in ['transient', 'duck']) {
            await stage('steal-$name');
            await until(
              () => session.audioStatus == 'paused',
              'Focus loss did not pause',
            );
            expect(
              WidgetsBinding.instance.lifecycleState,
              AppLifecycleState.resumed,
            );
            expect(session.state, SessionState.connected);
            await stage('focus-paused-$name');
            await stage('release-$name');
            await until(
              () => session.audioStatus == 'playing',
              'Focus gain did not resume',
            );
            await stage('focus-restored-$name');
          }
        }
        await tester.tap(find.byTooltip('返回电脑列表（保持连接）'));
        await tester.pumpAndSettle();
        await until(
          () => session.audioStatus == 'paused',
          'Inactive session is still audible',
        );
        await stage('inactive-$i');
        await tester.tap(find.text(profiles[i].name));
        await until(
          () => session.audioStatus == 'playing',
          'Returning to session did not resume',
        );
        expect(
          sessions.length,
          i + 1,
          reason: 'Audio resume must reuse the connection',
        );
        await stage('reactivated-$i');
        await stage('stream-complete-$i');
        await session.close();
        await stage('closed-$i');
        await tester.tap(find.byTooltip('返回电脑列表（保持连接）'));
        await tester.pumpAndSettle();
      }
      binding.reportData = {
        'audio':
            'actual TLS RDPSND/OpenSL ES, production Workspace lifecycle and native Android audio focus',
        'iterations': 2,
        'physicalDevice': false,
      };
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      for (final session in sessions) {
        await session.close();
      }
      for (final profile in profiles) {
        await store.remove(profile);
      }
      store.dispose();
      if (await protocol.exists()) await protocol.delete(recursive: true);
      if (await config.exists()) await config.delete();
    }
  });
}
