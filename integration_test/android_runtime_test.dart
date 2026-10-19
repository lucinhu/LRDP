import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/app.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/data/transfer_folder.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/rdp/native_bindings.dart';
import 'package:lrdp/ui/remote_view.dart';
import 'package:lrdp/ui/remote_surface.dart';
import 'package:lrdp/ui/mobile_keyboard.dart';
import 'package:lrdp/ui/certificate_dialog.dart';
import 'cursor_scenario.dart';

// This entrypoint is built only into an integration APK, never a distribution.
// The host harness supplies disposable loopback services through adb reverse.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  binding.shouldPropagateDevicePointerEvents = true;
  late Directory support, protocol;
  late Map<String, dynamic> fixture;
  const vault = FlutterSecureStorage();

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ready, {
    String? reason,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(ready(), isTrue, reason: reason);
    expect(tester.takeException(), isNull);
  }

  Future<void> waitWithoutFrames(bool Function() ready, String reason) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(ready(), isTrue, reason: reason);
  }

  // Pause each screenshot/action stage until the host captures the actual
  // Android screen (including the IME and native document/share activities).
  Future<void> stage(WidgetTester tester, String name) async {
    final acknowledgements = Directory(
      '${support.path}/lrdp-integration-captures',
    );
    await acknowledgements.create(recursive: true);
    final ack = File('${acknowledgements.path}/$name.ack');
    if (await ack.exists()) await ack.delete();
    await File(
      '${support.path}/lrdp-integration-stage',
    ).writeAsString(name, flush: true);
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (!await ack.exists() && DateTime.now().isBefore(deadline)) {
      // Native activities and Home can suspend frame delivery. Await the host
      // independently of vsync; fullyLive keeps rendering when Android resumes.
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    expect(await ack.exists(), isTrue, reason: 'Host did not complete $name');
  }

  setUpAll(() async {
    expect(Platform.isAndroid, isTrue);
    support = await getApplicationSupportDirectory();
    protocol = Directory('${support.path}/lrdp-集成测试协议');
    if (await protocol.exists()) await protocol.delete(recursive: true);
    await protocol.create(recursive: true);
    await Directory(
      '${support.path}/lrdp-integration-captures',
    ).create(recursive: true);
    final configuration = File('${support.path}/lrdp-integration-config.json');
    if (await configuration.exists()) await configuration.delete();
    await File(
      '${support.path}/lrdp-integration-stage',
    ).writeAsString('android-config', flush: true);
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (!await configuration.exists() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fixture =
        jsonDecode(await configuration.readAsString()) as Map<String, dynamic>;
    binding.reportData = {
      'platform': 'Android',
      'protocolDirectory': protocol.path,
    };
  });

  tearDownAll(() async {
    if (await protocol.exists()) await protocol.delete(recursive: true);
    final marker = File('${support.path}/lrdp-integration-stage');
    if (await marker.exists()) await marker.delete();
    final configuration = File('${support.path}/lrdp-integration-config.json');
    if (await configuration.exists()) await configuration.delete();
  });

  testWidgets('Android Keystore, native library, RDPDR and Unicode roundtrip', (
    tester,
  ) async {
    final key = 'lrdp.integration.${DateTime.now().microsecondsSinceEpoch}';
    try {
      await vault.write(key: key, value: 'disposable-fixture-value');
      expect(await vault.read(key: key), 'disposable-fixture-value');
    } finally {
      await vault.delete(key: key);
    }
    expect(await vault.read(key: key), isNull);
    final profile = ConnectionProfile(
      id: 'android-files',
      name: 'Android 协议夹具',
      host: '127.0.0.1',
      port: fixture['filePort'] as int,
      nla: false,
      clipboard: false,
      fileTransfer: true,
    );
    expect(profile.port, greaterThan(0));
    final folder = Directory(TransferFolder.pathFor(protocol.path, profile));
    await folder.create(recursive: true);
    final uploadHeader = utf8.encode('LRDP upload: 中文文件\n');
    final upload = Uint8List(uploadHeader.length + 1024 * 1024)
      ..setRange(0, uploadHeader.length, uploadHeader);
    for (var i = uploadHeader.length; i < upload.length; i++) {
      upload[i] = (i - uploadHeader.length) & 255;
    }
    await File('${folder.path}/上传测试.txt').writeAsBytes(upload, flush: true);
    final outside = File('${folder.parent.path}/outside.txt');
    await outside.writeAsString('must remain outside the redirected directory');
    final session = RdpSession(profile, protocolDirectory: protocol.path);
    try {
      await session.connect(
        password: '',
        acceptedFingerprint: fixture['filePin'] as String,
      );
      await waitFor(
        tester,
        () =>
            session.state == SessionState.connected ||
            session.state == SessionState.failed,
        reason: 'Android native TLS connection did not finish',
      );
      expect(session.state, SessionState.connected, reason: session.error);
      expect(session.version, contains('3.32.2'));
      session.text('中文输入');
      final received = File('${folder.path}/收到的文件.txt');
      final header = utf8.encode('LRDP download: 远程写回\n');
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while ((!await received.exists() ||
              await received.length() != header.length + 1024 * 1024) &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      final actual = await received.readAsBytes();
      expect(actual.length, header.length + 1024 * 1024);
      expect(actual.sublist(0, header.length), header);
      for (var i = header.length; i < actual.length; i++) {
        if (actual[i] != 255 - ((i - header.length) & 255)) {
          fail('Downloaded byte mismatch at $i');
        }
      }
      expect(
        await outside.readAsString(),
        'must remain outside the redirected directory',
      );
      binding.reportData!['androidProtocol'] =
          'Keystore + pinned TLS + FreeRDP 3.32.2 + 1 MiB bidirectional files + Unicode';
    } finally {
      await session.close();
      session.dispose();
    }
  });

  testWidgets('Android phone composer confirms clipboard Chinese paste', (
    tester,
  ) async {
    final session = RdpSession(
      ConnectionProfile(
        id: 'android-paste',
        name: 'Private clipboard',
        host: '127.0.0.1',
        port: fixture['pastePort'] as int,
        nla: false,
      ),
      protocolDirectory: protocol.path,
    );
    try {
      await session.connect(
        password: '',
        acceptedFingerprint: fixture['filePin'] as String,
      );
      await waitFor(
        tester,
        () =>
            session.state == SessionState.connected &&
            session.clipboardSupported,
        reason: 'Android clipboard channel did not become ready',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MobileKeyboard(
                session: session,
                close: () {},
                shortcuts: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('remoteTextInput'));
      await tester.enterText(input, 'LRDP 中文输入验证 你好');
      await tester.pump();
      await tester.tap(find.byKey(const Key('pasteRemoteText')));
      await tester.pump();
      await waitFor(
        tester,
        () => !session.pasteInProgress,
        reason: 'Android paste acknowledgement/data transfer',
      );
      expect(session.pasteError, isEmpty);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      binding.reportData!['androidClipboardPaste'] =
          'confirmed Chinese UTF-16 delivery and Ctrl+V from phone composer';
      await stage(tester, 'android-paste');
    } finally {
      await tester.pumpWidget(const SizedBox());
      await session.close();
      session.dispose();
    }
  });

  testWidgets(
    'Android real TLS cursor alpha, XOR, cached shapes, position and large pointer',
    (tester) async {
      final session = RdpSession(
        ConnectionProfile(
          id: 'android-cursor',
          name: 'Android cursor fixture',
          host: '127.0.0.1',
          port: fixture['cursorPort'] as int,
          nla: false,
        ),
        protocolDirectory: protocol.path,
      );
      try {
        await exerciseRdpCursor(
          session,
          fixture['filePin'] as String,
          inspect: (step) async {
            if (step != 3) return;
            final recorder = ui.PictureRecorder();
            Canvas(recorder).drawColor(const Color(0xff182d28), BlendMode.src);
            final picture = recorder.endRecording();
            session.image = picture.toImageSync(640, 320);
            picture.dispose();
            final boundaryKey = GlobalKey();
            final focus = FocusNode();
            final transform = TransformationController();
            try {
              await tester.pumpWidget(
                MaterialApp(
                  home: Scaffold(
                    body: Center(
                      child: SizedBox(
                        width: 320,
                        height: 320,
                        child: RepaintBoundary(
                          key: boundaryKey,
                          child: Focus(
                            focusNode: focus,
                            child: RemoteSurface(
                              session: session,
                              focus: focus,
                              transform: transform,
                              trackpad: true,
                              pan: false,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pump(const Duration(milliseconds: 150));
              final capture =
                  await (boundaryKey.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 1);
              final List<int> actual;
              try {
                final bytes = await capture.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                );
                actual = bytes!.buffer.asUint8List().sublist(
                  (158 * 320 + 162) * 4,
                  (158 * 320 + 162) * 4 + 4,
                );
                expect(
                  actual,
                  [231, 210, 215, 255],
                  reason:
                      'Android renderer must XOR the real decoded monochrome mask against the known test backdrop',
                );
              } finally {
                capture.dispose();
              }
              await File(
                '${support.path}/lrdp-integration-cursor-render.json',
              ).writeAsString(
                jsonEncode({
                  'pixel': actual,
                  'source':
                      'real TLS monochrome pointer, known synthetic test backdrop',
                  'nativeAbi': NativeBindings().abiVersion(),
                }),
              );
              await stage(tester, 'android-cursor-xor');
              binding.reportData!['androidCursorComposite'] = actual;
            } finally {
              await tester.pumpWidget(const SizedBox());
              focus.dispose();
              transform.dispose();
            }
          },
        );
        binding.reportData!['androidCursor'] =
            'premultiplied alpha + AND/XOR planes + cached/null/default + server position + 384x384';
      } finally {
        await session.close();
        session.dispose();
      }
    },
  );

  testWidgets('Android phone workflow, IME, rotation, document picker and sharing', (
    tester,
  ) async {
    final previousErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      FlutterError.dumpErrorToConsole(details, forceReport: true);
      previousErrorHandler?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousErrorHandler);
    final profile = ConnectionProfile(
      id: 'android-ui',
      name: 'Android 回环桌面',
      host: '127.0.0.1',
      port: fixture['uiPort'] as int,
      username: 'fixture',
      nla: false,
      fileTransfer: true,
    );
    expect(profile.port, greaterThan(0));
    await vault.delete(key: 'certificate.${profile.id}');
    SharedPreferences.setMockInitialValues({
      'profiles.v1': jsonEncode([profile.toJson()]),
    });
    final store = ProfileStore(await SharedPreferences.getInstance());
    await store.load();
    await tester.pumpWidget(
      Listener(
        onPointerDown: (event) {
          File('${support.path}/lrdp-integration-pointer.json').writeAsString(
            jsonEncode({
              'x': event.position.dx,
              'y': event.position.dy,
              'source': binding.pointerEventSource.name,
              'propagate': binding.shouldPropagateDevicePointerEvents,
            }),
          );
        },
        child: LrdpApp(store: store, protocolDirectory: protocol.path),
      ),
    );
    await tester.pumpAndSettle();
    await stage(tester, 'android-workspace');
    await stage(tester, 'android-editor-landscape');
    await waitFor(
      tester,
      () => tester.view.physicalSize.width > tester.view.physicalSize.height,
      reason: 'Editor landscape orientation',
    );
    await tester.tap(find.text('添加电脑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profileAddress')));
    await waitFor(
      tester,
      () => tester.view.viewInsets.bottom > 0,
      reason: 'System IME did not appear',
    );
    expect(
      find.widgetWithText(OutlinedButton, '保存连接').hitTestable(),
      findsOneWidget,
    );
    final keyboardTop =
        (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
        tester.view.devicePixelRatio;
    for (final action in [
      find.widgetWithText(OutlinedButton, '保存连接'),
      find.byKey(const Key('saveAndConnect')),
    ]) {
      expect(action.hitTestable(), findsOneWidget);
      expect(tester.getRect(action).bottom, lessThanOrEqualTo(keyboardTop));
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    }
    await stage(tester, 'android-editor-ime');
    await tester.tap(find.byTooltip('关闭'));
    await stage(tester, 'android-editor-portrait');
    await waitFor(
      tester,
      () => tester.view.physicalSize.height > tester.view.physicalSize.width,
      reason: 'Editor returned to portrait',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(profile.name));
    await waitFor(
      tester,
      () => find.text('连接到 ${profile.name}').evaluate().isNotEmpty,
    );
    await tester.enterText(find.byType(TextFormField).last, 'fixture');
    await tester.tap(find.widgetWithText(FilledButton, '连接').last);
    await waitFor(tester, () => find.text('指纹匹配，继续').evaluate().isNotEmpty);
    await stage(tester, 'android-certificate');
    await tester.tap(find.text('指纹匹配，继续'));
    await waitFor(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    var painted = false;
    List<int>? actualPixel;
    final paintDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (!painted && DateTime.now().isBefore(paintDeadline)) {
      final image = tester
          .widget<RawImage>(find.byType(RawImage).first)
          .image!
          .clone();
      try {
        expect(image.width, 1280);
        expect(image.height, 800);
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final center = (400 * image.width + 640) * 4;
        actualPixel = pixels!.buffer.asUint8List().sublist(center, center + 4);
        // Color-transform/quantization codecs can round RGB by one level.
        painted =
            (actualPixel[0] - 24).abs() <= 2 &&
            (actualPixel[1] - 45).abs() <= 2 &&
            (actualPixel[2] - 40).abs() <= 2 &&
            actualPixel[3] == 255;
      } finally {
        image.dispose();
      }
      if (!painted) await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      painted,
      isTrue,
      reason: 'Real desktop paint not received; last RGBA=$actualPixel',
    );
    await stage(tester, 'android-touch-input');
    await stage(tester, 'android-background-resume');
    expect(find.byType(RawImage), findsOneWidget);
    final remote = tester.widget<RemoteView>(find.byType(RemoteView));
    final liveSession = remote.session;
    await waitFor(
      tester,
      () => liveSession.hasDecodedAvc && liveSession.image != null,
      reason: 'Android AVC decoder was not exercised',
    );
    binding.reportData!['androidAvc'] =
        'successful AVC surface decode observed in native bridge with actual RDP image';
    await stage(tester, 'android-avc');
    final recovery = remote.recovery!;
    final previousConnection = liveSession.connectedAt;
    final originalPin = liveSession.fingerprint;
    final previousFrames = liveSession.frames;
    await stage(tester, 'android-background-loss');
    await waitWithoutFrames(
      () => recovery.suspended,
      'Background network loss must suspend the retry countdown',
    );
    expect(binding.lifecycleState, AppLifecycleState.paused);
    expect(recovery.attempts, 0);
    expect(liveSession.endReason, SessionEndReason.transport);
    await stage(tester, 'android-network-resume');
    await waitFor(
      tester,
      () =>
          liveSession.state == SessionState.connected &&
          liveSession.connectedAt != previousConnection &&
          liveSession.frames > previousFrames &&
          liveSession.image != null,
      reason: 'Android resume must receive a new real RDP image',
    );
    expect(liveSession.fingerprint, originalPin);
    expect(recovery.attempts, 1);
    await stage(tester, 'android-network-recovered');
    await tester.tap(find.text('键盘'));
    await waitFor(tester, () => tester.view.viewInsets.bottom > 0);
    await tester.enterText(find.byKey(const Key('remoteTextInput')), '手机中文输入');
    await stage(tester, 'android-keyboard');
    await tester.tap(find.byTooltip('发送文字'));
    await stage(tester, 'android-rotate-landscape');
    await waitFor(
      tester,
      () => tester.view.physicalSize.width > tester.view.physicalSize.height,
    );
    // Android can close the IME while rotating. Open it in the new geometry
    // so this stage verifies the actual landscape keyboard constraints.
    await tester.tap(find.byKey(const Key('remoteTextInput')));
    await waitFor(
      tester,
      () => tester.view.viewInsets.bottom > 0,
      reason: 'Landscape system IME did not appear',
    );
    expect(tester.takeException(), isNull);
    await stage(tester, 'android-landscape-keyboard');
    await tester.tap(find.byTooltip('收起键盘'));
    await stage(tester, 'android-rotate-portrait');
    await waitFor(
      tester,
      () => tester.view.physicalSize.height > tester.view.physicalSize.width,
    );
    await tester.tap(find.text('文件'));
    await waitFor(tester, () => find.text('文件中转站').evaluate().isNotEmpty);
    await tester.tap(find.text('放入本地文件'));
    await stage(tester, 'android-document-picker');
    await waitFor(
      tester,
      () => find.text('手机选中的中文文件.txt').evaluate().isNotEmpty,
    );
    final chosen = File(
      '${TransferFolder.pathFor(protocol.path, profile)}/手机选中的中文文件.txt',
    );
    expect(await chosen.readAsString(), '来自 Android 系统文件选择器的中文内容\n');
    final shareRect = tester.getRect(find.byTooltip('保存或分享').first);
    await File(
      '${support.path}/lrdp-integration-share-target.json',
    ).writeAsString(
      jsonEncode({
        'x': shareRect.center.dx,
        'y': shareRect.center.dy,
        'dpr': tester.view.devicePixelRatio,
        'lifecycle': binding.lifecycleState?.name,
      }),
    );
    await stage(tester, 'android-files');
    // The host opens SharePlus with a device tap after DocumentsUI resumes.
    await stage(tester, 'android-share-sheet');
    await waitFor(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      reason: 'Android share result did not return to the file panel',
    );
    await waitFor(
      tester,
      () => binding.lifecycleState == AppLifecycleState.resumed,
      reason: 'Android must resume before injecting the foreground failure',
    );
    expect(liveSession.state, SessionState.connected);
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pumpAndSettle();
    // Hold the new handshake until Android is paused. Then release a server
    // with a different certificate and verify no route is pushed in background.
    await stage(tester, 'android-certificate-hold');
    debugPrint(
      'Certificate recovery: lifecycle=${binding.lifecycleState}, '
      'state=${liveSession.state}, reason=${liveSession.endReason}, '
      'attempts=${recovery.attempts}, pending=${recovery.pending}',
    );
    await waitFor(
      tester,
      () => recovery.running,
      reason: 'Expected a real automatic connection waiting at the fault proxy',
    );
    await stage(tester, 'android-certificate-inflight');
    await waitWithoutFrames(
      () => liveSession.state == SessionState.certificateRequired,
      'Changed certificate did not reach the Android native worker',
    );
    expect(binding.lifecycleState, AppLifecycleState.paused);
    expect(liveSession.endReason, SessionEndReason.certificate);
    expect(liveSession.fingerprint, isNot(originalPin));
    expect(
      tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
      isFalse,
      reason:
          'A certificate dialog route must not be pushed while Android is paused',
    );
    expect(recovery.pending, isFalse);
    await stage(tester, 'android-certificate-deferred');
    await stage(tester, 'android-certificate-return');
    await waitFor(
      tester,
      () => find.byType(CertificateDialog).evaluate().isNotEmpty,
    );
    expect(find.text('远程电脑的证书发生变化'), findsOneWidget);
    await stage(tester, 'android-certificate-changed');
    await tester.tap(find.text('取消连接'));
    await waitFor(
      tester,
      () => find.byType(CertificateDialog).evaluate().isEmpty,
    );
    expect(recovery.pending, isFalse);
    binding.reportData!['androidRecovery'] =
        'actual TCP EOF while paused: no retry handshakes; resume fresh RDP image; changed certificate in-flight while paused: no dialog route until resumed';
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('断开连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('断开连接'));
    await waitFor(tester, () => find.byType(RemoteView).evaluate().isEmpty);
    expect(tester.takeException(), isNull);
    binding.reportData!['androidUi'] =
        'actual IME + touch + background + rotation + system picker + SharePlus';
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    await vault.delete(key: 'certificate.${profile.id}');
  });
}
