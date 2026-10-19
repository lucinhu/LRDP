import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/certificate_dialog.dart';
import 'package:lrdp/ui/theme.dart';
import 'package:lrdp/ui/workspace_screen.dart';

// A failed platform vault must not prevent temporary login or cause fallback
// password persistence. The actual protocol/session/FFI are not replaced.
class UnavailableVault extends Fake implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      return Future<String?>.error(StateError('Test vault unavailable'));
    }
    throw StateError('Temporary login must not write to the vault');
  }
}

void main() {
  testWidgets(
    'real NLA failure repairs credentials in phone UI and retains one-time pin',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ProfileStore(preferences, vault: UnavailableVault());
      final profile = ConnectionProfile(
        id: 'auth-protocol',
        name: '隔离认证测试',
        host: '127.0.0.1',
        port: int.parse(Platform.environment['LRDP_TEST_PORT']!),
        username: 'incorrect-user',
        domain: 'INCORRECT',
        nla: true,
        clipboard: false,
      );
      await store.save(profile);
      final directory = Directory.systemTemp.createTempSync('lrdp-auth-ui-');
      final sessions = <RdpSession>[];
      Future<void> until(bool Function() predicate, String label) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!predicate() && DateTime.now().isBefore(deadline)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pump();
        }
        expect(
          predicate(),
          isTrue,
          reason:
              '$label: ${sessions.map((s) => '${s.state}/${s.endReason}/0x${s.errorCode.toRadixString(16)} ${s.error}').join('; ')}',
        );
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(
              Brightness.light,
            ).copyWith(platform: TargetPlatform.android),
            home: WorkspaceScreen(
              store: store,
              protocolDirectory: directory.path,
              sessionFactory: (p, directory) {
                final session = RdpSession(p, protocolDirectory: directory);
                sessions.add(session);
                return session;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(profile.name));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('loginPassword')),
          'incorrect-test-password',
        );
        await tester.tap(find.byKey(const Key('submitLogin')));
        await until(
          () => find.byType(CertificateDialog).evaluate().isNotEmpty,
          'Initial certificate confirmation',
        );
        await tester.pump(const Duration(milliseconds: 300));
        final pin = sessions.single.fingerprint;
        expect(pin.replaceAll(':', '').length, 64);
        await tester.tap(find.text('指纹匹配，继续'));
        await until(
          () => find.text('重新登录').evaluate().isNotEmpty,
          'NLA denial offers credential repair',
        );
        expect(sessions.single.endReason, SessionEndReason.authentication);
        expect(find.text('登录未成功'), findsOneWidget);
        expect(find.textContaining('ERRCONNECT'), findsNothing);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('重新登录'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('loginUser')), 'lrdptest');
        await tester.enterText(
          find.byKey(const Key('loginDomain')),
          'LRDPTEST',
        );
        await tester.enterText(
          find.byKey(const Key('loginPassword')),
          'LRDP-test-password-2026',
        );
        await tester.tap(find.byKey(const Key('submitLogin')));
        await until(
          () => sessions.length == 2 && sessions.last.image != null,
          'Corrected principal and password produce actual decoded RDP frame',
        );
        expect(sessions.last.state, SessionState.connected);
        expect(sessions.last.profile.username, 'lrdptest');
        expect(sessions.last.profile.domain, 'LRDPTEST');
        expect(sessions.last.image!.width, 1280);
        expect(sessions.last.image!.height, 800);
        expect(find.byType(CertificateDialog), findsNothing);
        expect(store.profiles.single.username, 'incorrect-user');
        expect(store.profiles.single.domain, 'INCORRECT');
        expect(
          preferences.getString('profiles.v1'),
          isNot(contains('password-2026')),
        );
        await tester.tap(find.byTooltip('返回电脑列表（保持连接）'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(profile.name));
        await tester.pumpAndSettle();
        expect(sessions.length, 2);
        expect(sessions.last.state, SessionState.connected);
        stdout.writeln(
          'PASS: real NLA denial -> phone credential repair -> pinned TLS and decoded RDP frame; temporary principal reused without vault persistence',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        Future.wait(sessions.map((session) => session.close())).then((_) {
          closed = true;
        });
        await until(() => closed, 'Native worker shutdown');
        await tester.pump();
        store.dispose();
        directory.deleteSync(recursive: true);
      }
    },
    skip: Platform.environment['LRDP_TEST_PORT'] == null,
  );
}
