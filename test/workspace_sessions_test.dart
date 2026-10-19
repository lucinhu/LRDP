import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/certificate_dialog.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/mobile_keyboard.dart';
import 'package:lrdp/ui/theme.dart';
import 'package:lrdp/ui/workspace_screen.dart';

class TestVault extends Fake implements FlutterSecureStorage {
  final values = <String, String>{};
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(values[key]);
      case #write:
        values[key] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

class TestSession extends RdpSession {
  TestSession(super.profile);
  final passwords = <String>[], pins = <String>[];
  bool disposed = false, visible = true;
  @override
  Future<void> connect({
    required String password,
    String acceptedFingerprint = '',
  }) async {
    passwords.add(password);
    pins.add(acceptedFingerprint);
    endReason = SessionEndReason.none;
    errorCode = 0;
    error = '';
    state = SessionState.connecting;
    notifyListeners();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(const Color(0xff182d28), BlendMode.src);
    final picture = recorder.endRecording();
    image?.dispose();
    image = picture.toImageSync(800, 400);
    picture.dispose();
    state = SessionState.connected;
    connectedAt = DateTime.now();
    notifyListeners();
  }

  void requireCertificate(String value) {
    state = SessionState.certificateRequired;
    endReason = SessionEndReason.certificate;
    fingerprint = value;
    notifyListeners();
  }

  @override
  void setVisible(bool value) {
    visible = value;
    super.setVisible(value);
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  void background(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void foreground(WidgetTester tester) {
    if (tester.binding.lifecycleState == AppLifecycleState.resumed) return;
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  const original = ConnectionProfile(
    id: 'live',
    name: '测试电脑',
    host: '192.0.2.1',
    username: 'tester',
    rememberPassword: true,
  );
  Future<ProfileStore> prepare(List<ConnectionProfile> profiles) async {
    SharedPreferences.setMockInitialValues({});
    final store = ProfileStore(
      await SharedPreferences.getInstance(),
      vault: TestVault(),
    );
    for (final p in profiles) {
      await store.save(p, password: 'initial-secret');
    }
    return store;
  }

  Future<void> mount(
    WidgetTester tester,
    ProfileStore store,
    List<TestSession> sessions, {
    bool desktop = false,
  }) async {
    tester.view.physicalSize = desktop
        ? const Size(1440, 1000)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light).copyWith(
          platform: desktop ? TargetPlatform.linux : TargetPlatform.android,
        ),
        home: WorkspaceScreen(
          store: store,
          sessionFactory: (p, _) {
            final session = TestSession(p);
            sessions.add(session);
            return session;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> library(WidgetTester tester) async {
    await tester.tap(find.byTooltip('返回电脑列表（保持连接）'));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String name) async {
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  testWidgets('each open phone session retains its viewport and input mode', (
    tester,
  ) async {
    const other = ConnectionProfile(
      id: 'other',
      name: '另一台电脑',
      host: '192.0.2.2',
      username: 'tester',
      rememberPassword: true,
    );
    final store = await prepare([original, other]);
    final sessions = <TestSession>[];
    await mount(tester, store, sessions);
    await open(tester, original.name);
    await tester.tap(find.text('触控板'));
    await tester.tap(find.text('缩放'));
    await tester.pumpAndSettle();
    final surface = tester.widget<RemoteSurface>(find.byType(RemoteSurface));
    surface.transform.value = Matrix4.diagonal3Values(3, 3, 1)
      ..setTranslationRaw(
        -500,
        -tester.getSize(find.byType(RemoteSurface)).height,
        0,
      );
    await tester.pump();
    final matrix = surface.transform.value.clone();
    await library(tester);
    await open(tester, other.name);
    final second = tester.widget<RemoteSurface>(find.byType(RemoteSurface));
    expect(second.trackpad, isTrue);
    expect(second.pan, isFalse);
    expect(second.transform.value.getMaxScaleOnAxis(), 1);
    await library(tester);
    await open(tester, original.name);
    final restored = tester.widget<RemoteSurface>(find.byType(RemoteSurface));
    expect(restored.trackpad, isFalse);
    expect(restored.pan, isTrue);
    for (var i = 0; i < 16; i++) {
      expect(
        restored.transform.value.storage[i],
        closeTo(matrix.storage[i], 1e-8),
      );
    }
    expect(sessions, hasLength(2));
    expect(sessions.first.passwords, hasLength(1));
    await tester.tap(find.text('键盘'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(find.byType(MobileKeyboard), findsOneWidget);
    await library(tester);
    tester.view.viewInsets = const FakeViewPadding();
    await open(tester, original.name);
    expect(find.byType(MobileKeyboard), findsNothing);
    final afterKeyboard = tester.widget<RemoteSurface>(
      find.byType(RemoteSurface),
    );
    expect(afterKeyboard.trackpad, isFalse);
    expect(afterKeyboard.pan, isTrue);
    for (var i = 0; i < 16; i++) {
      expect(
        afterKeyboard.transform.value.storage[i],
        closeTo(matrix.storage[i], 1e-8),
      );
    }
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('断开连接'));
    await tester.pumpAndSettle();
    await library(tester);
    await open(tester, original.name);
    final fresh = tester.widget<RemoteSurface>(find.byType(RemoteSurface));
    expect(sessions, hasLength(3));
    expect(sessions.first.disposed, isTrue);
    expect(fresh.trackpad, isTrue);
    expect(fresh.pan, isFalse);
    expect(fresh.transform.value.getMaxScaleOnAxis(), 1);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });

  testWidgets('desktop tab switching retains each connection view', (
    tester,
  ) async {
    const other = ConnectionProfile(
      id: 'desktop-other',
      name: '桌面第二台',
      host: '192.0.2.2',
      username: 'tester',
      rememberPassword: true,
    );
    final store = await prepare([original, other]);
    final sessions = <TestSession>[];
    await mount(tester, store, sessions, desktop: true);
    await open(tester, original.name);
    for (final label in ['直接触控', '控制电脑']) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    final first = tester.widget<RemoteSurface>(find.byType(RemoteSurface));
    first.transform.value = Matrix4.diagonal3Values(2, 2, 1)
      ..setTranslationRaw(
        -500,
        -tester.getSize(find.byType(RemoteSurface)).height / 2,
        0,
      );
    await tester.pump();
    final matrix = first.transform.value.clone();
    await tester.tap(find.text('连接库'));
    await tester.pumpAndSettle();
    await open(tester, other.name);
    final second = tester.widget<RemoteSurface>(find.byType(RemoteSurface));
    expect(second.trackpad, isFalse);
    expect(second.pan, isFalse);
    expect(second.transform.value.getMaxScaleOnAxis(), 1);
    await tester.tap(find.text(original.name));
    await tester.pumpAndSettle();
    final restored = tester.widget<RemoteSurface>(find.byType(RemoteSurface));
    expect(restored.trackpad, isTrue);
    expect(restored.pan, isTrue);
    for (var i = 0; i < 16; i++) {
      expect(
        restored.transform.value.storage[i],
        closeTo(matrix.storage[i], 1e-8),
      );
    }
    expect(sessions, hasLength(2));
    expect(sessions.first.passwords, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });

  testWidgets(
    'temporary login repair retains verified pin and active session without saving credentials',
    (tester) async {
      final store = await prepare([original]);
      final sessions = <TestSession>[];
      await mount(tester, store, sessions);
      await open(tester, original.name);
      sessions.first.requireCertificate('temporary-exact-pin');
      await tester.pumpAndSettle();
      await tester.tap(find.text('指纹匹配，继续'));
      await tester.pumpAndSettle();
      expect(sessions.first.pins.last, 'temporary-exact-pin');
      final failed = sessions.first;
      failed.state = SessionState.failed;
      failed.endReason = SessionEndReason.authentication;
      failed.errorCode = 0x20014;
      failed.error = 'ERRCONNECT_LOGON_FAILURE';
      failed.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('登录未成功'), findsOneWidget);
      expect(find.textContaining('ERRCONNECT_LOGON_FAILURE'), findsNothing);
      await tester.tap(find.text('重新登录'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('loginPassword')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(sessions.length, 1);
      await tester.tap(find.text('重新登录'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('loginUser')), 'replacement');
      await tester.enterText(find.byKey(const Key('loginDomain')), 'LAB');
      await tester.enterText(
        find.byKey(const Key('loginPassword')),
        'temporary-secret',
      );
      await tester.tap(find.byKey(const Key('submitLogin')));
      await tester.pumpAndSettle();
      expect(sessions.length, 2);
      expect(sessions.first.disposed, isTrue);
      expect(sessions.last.profile.username, 'replacement');
      expect(sessions.last.profile.domain, 'LAB');
      expect(sessions.last.pins.single, 'temporary-exact-pin');
      expect(store.profiles.single.username, 'tester');
      expect(await store.password(original), 'initial-secret');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('profiles.v1'),
        isNot(contains('temporary-secret')),
      );
      await library(tester);
      await open(tester, original.name);
      expect(sessions.length, 2);
      await library(tester);
      await store.update(original.copyWith(host: '192.0.2.9'));
      await tester.pumpAndSettle();
      await open(tester, original.name);
      expect(sessions.length, 3);
      expect(
        sessions.last.pins.single,
        isEmpty,
        reason: 'A temporary pin must not follow a profile to another endpoint',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      store.dispose();
    },
  );

  testWidgets(
    'changed connection options replace the live session; metadata edits reuse it',
    (tester) async {
      final store = await prepare([original]);
      final sessions = <TestSession>[];
      await mount(tester, store, sessions);
      await open(tester, original.name);
      expect(sessions.length, 1);
      expect(sessions.single.passwords, ['initial-secret']);
      await library(tester);
      final changed = original.copyWith(
        fileTransfer: true,
        audio: true,
        clipboard: false,
        autoReconnect: false,
        width: 1920,
        height: 1080,
      );
      await store.update(changed);
      await tester.pumpAndSettle();
      await open(tester, changed.name);
      expect(sessions.length, 2);
      expect(sessions.first.disposed, isTrue);
      expect(sessions.last.profile.fileTransfer, isTrue);
      expect(sessions.last.profile.audio, isTrue);
      expect(sessions.last.profile.clipboard, isFalse);
      expect(sessions.last.profile.autoReconnect, isFalse);
      expect(sessions.last.profile.width, 1920);
      await library(tester);
      await store.update(
        changed.copyWith(name: '改名电脑', group: '新分组', favorite: true),
      );
      await tester.pumpAndSettle();
      await open(tester, '改名电脑');
      expect(sessions.length, 2);
      expect(sessions.last.passwords.length, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      store.dispose();
    },
  );

  testWidgets(
    'save and connect applies a newly entered password even at the same address',
    (tester) async {
      final store = await prepare([original]);
      final sessions = <TestSession>[];
      await mount(tester, store, sessions);
      await open(tester, original.name);
      await library(tester);
      await tester.tap(find.byTooltip('连接操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑连接'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '密码',
        ),
        'updated-secret',
      );
      await tester.tap(find.byKey(const Key('saveAndConnect')));
      await tester.pumpAndSettle();
      expect(sessions.length, 2);
      expect(sessions.first.disposed, isTrue);
      expect(sessions.last.passwords, ['updated-secret']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      store.dispose();
    },
  );

  testWidgets(
    'mobile background pauses frame delivery and defers certificate dialogs in order',
    (tester) async {
      final second = original.copyWith(name: 'second');
      final other = ConnectionProfile(
        id: 'second',
        name: second.name,
        host: '192.0.2.2',
        username: 'tester',
        rememberPassword: true,
      );
      final store = await prepare([original, other]);
      final sessions = <TestSession>[];
      await mount(tester, store, sessions);
      await open(tester, original.name);
      await library(tester);
      await open(tester, other.name);
      background(tester);
      addTearDown(() => foreground(tester));
      expect(sessions.every((s) => !s.visible), isTrue);
      sessions[0].requireCertificate('first-fingerprint');
      sessions[1].requireCertificate('second-fingerprint');
      await tester.pump();
      expect(find.byType(CertificateDialog), findsNothing);
      foreground(tester);
      await tester.pumpAndSettle();
      expect(find.byType(CertificateDialog), findsOneWidget);
      expect(find.text('first-fingerprint'), findsOneWidget);
      expect(sessions[0].visible, isFalse);
      expect(sessions[1].visible, isTrue);
      await tester.tap(find.text('取消连接'));
      await tester.pumpAndSettle();
      expect(find.byType(CertificateDialog), findsOneWidget);
      expect(find.text('second-fingerprint'), findsOneWidget);
      await tester.tap(find.text('取消连接'));
      await tester.pumpAndSettle();
      expect(find.byType(CertificateDialog), findsNothing);
      background(tester);
      foreground(tester);
      await tester.pumpAndSettle();
      expect(
        find.byType(CertificateDialog),
        findsNothing,
        reason: 'Cancelled prompts must not reopen on resume',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      store.dispose();
    },
  );
}
