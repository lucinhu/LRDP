import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/app.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';

class _VolatileVault extends Fake implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      final key = invocation.namedArguments[#key] as String;
      return Future<String?>.value(
        key.startsWith('password.') ? 'fixture' : null,
      );
    }
    return Future<void>.value();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native runner connects, confirms certificate, draws and closes',
    (tester) async {
      final phone = Platform.environment['LRDP_PHONE_UI'] == '1';
      if (phone) {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => binding.setSurfaceSize(null));
      }
      final port = int.parse(Platform.environment['LRDP_TEST_PORT']!);
      final private = await Directory.systemTemp.createTemp('lrdp-live-ui-');
      addTearDown(() => private.delete(recursive: true));
      final profile = ConnectionProfile(
        id: 'live',
        name: '私有回环桌面',
        host: '127.0.0.1',
        port: port,
        username: 'fixture',
        nla: false,
        rememberPassword: false,
        fileTransfer: true,
      );
      SharedPreferences.setMockInitialValues({
        'profiles.v1': jsonEncode([profile.toJson()]),
      });
      final store = ProfileStore(
        await SharedPreferences.getInstance(),
        vault: _VolatileVault(),
      );
      await store.load();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: phone
              ? MediaQuery(
                  data: const MediaQueryData(size: Size(390, 844)),
                  child: LrdpApp(store: store, protocolDirectory: private.path),
                )
              : LrdpApp(store: store, protocolDirectory: private.path),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> waitFor(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(condition(), isTrue);
        expect(tester.takeException(), isNull);
      }

      if (phone) {
        await capture(tester, boundary, 'phone-workspace');
        await tester.tap(find.text('添加电脑'));
        await tester.pumpAndSettle();
        await capture(tester, boundary, 'phone-editor');
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('私有回环桌面'));
      await waitFor(() => find.text('连接到 私有回环桌面').evaluate().isNotEmpty);
      await tester.enterText(find.byType(TextFormField).last, 'fixture');
      await tester.tap(find.widgetWithText(FilledButton, '连接').last);
      await waitFor(() => find.text('指纹匹配，继续').evaluate().isNotEmpty);
      await tester.tap(find.text('指纹匹配，继续'));
      await waitFor(() => find.byType(RawImage).evaluate().isNotEmpty);
      final remote = tester.widget<RawImage>(find.byType(RawImage).first);
      expect(remote.image!.width, 1280);
      expect(remote.image!.height, 800);
      await tester.pump(const Duration(milliseconds: 500));
      await capture(
        tester,
        boundary,
        phone ? 'phone-remote' : 'remote-session',
      );
      if (phone) {
        await tester.tap(find.text('键盘'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(
          find.byKey(const Key('remoteTextInput')),
          '中文协议测试',
        );
        await capture(tester, boundary, 'phone-keyboard');
        await tester.tap(find.byTooltip('发送文字'));
        await tester.tap(find.byTooltip('收起键盘'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('文件'));
        await waitFor(
          () => find.text(r'\\tsclient\LRDP').evaluate().isNotEmpty,
        );
        await capture(tester, boundary, 'phone-files');
        await tester.tap(find.byTooltip('关闭').last);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('更多'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('断开连接'));
      } else {
        await tester.tap(find.byTooltip('发送文字'));
        await waitFor(() => find.text('发送到远程电脑').evaluate().isNotEmpty);
        await tester.enterText(find.byType(TextField), '中文协议测试');
        await tester.tap(find.text('发送到远程电脑'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byTooltip('文件中转站'));
        await waitFor(
          () => find.text(r'\\tsclient\LRDP').evaluate().isNotEmpty,
        );
        await tester.tap(find.byTooltip('关闭').last);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.drag(
          find
              .byWidgetPredicate(
                (widget) =>
                    widget is ListView &&
                    widget.scrollDirection == Axis.horizontal,
              )
              .last,
          const Offset(-1200, 0),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byTooltip('断开连接'));
      }
      await waitFor(() => find.byType(RawImage).evaluate().isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}

Future<void> capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  await tester.pump(const Duration(milliseconds: 200));
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await render.toImage(pixelRatio: 1);
  final data = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  final root = Platform.environment['LRDP_PROJECT_ROOT']!;
  await File('$root/docs/screenshots/$name.png').writeAsBytes(data);
}
