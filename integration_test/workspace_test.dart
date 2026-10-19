import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/app.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/ui/transfer_dialog.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native desktop workspace renders, filters and switches appearance',
    (tester) async {
      // Documentation-only TEST-NET addresses; these are never connected.
      final profiles = [
        const ConnectionProfile(
          id: '1',
          name: '办公室工作站',
          host: '192.0.2.10',
          username: 'lucas',
          group: '工作',
          favorite: true,
        ),
        const ConnectionProfile(
          id: '2',
          name: '开发环境',
          host: '192.0.2.20',
          username: 'developer',
          group: '工作',
        ),
        const ConnectionProfile(
          id: '3',
          name: '家里的电脑',
          host: '192.0.2.30',
          group: '个人',
        ),
        const ConnectionProfile(
          id: '4',
          name: '测试服务器',
          host: '192.0.2.40',
          port: 3390,
          group: '实验室',
        ),
      ];
      SharedPreferences.setMockInitialValues({
        'profiles.v1': jsonEncode(profiles.map((p) => p.toJson()).toList()),
      });
      final store = ProfileStore(await SharedPreferences.getInstance());
      await store.load();
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: LrdpApp(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('办公室工作站'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Future<void> capture(String name) async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        image.dispose();
        final directory = Directory(
          '${Platform.environment['LRDP_PROJECT_ROOT'] ?? Directory.current.path}/docs/screenshots',
        );
        await directory.create(recursive: true);
        await File('${directory.path}/$name.png').writeAsBytes(bytes);
      }

      await capture('workspace');
      await tester.tap(find.byTooltip('外观'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(store.themeMode, ThemeMode.dark);
      expect(tester.takeException(), isNull);
      await capture('workspace-dark');
      await tester.tap(find.text('添加电脑').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('profileAddress')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('connection-editor');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      final exchange = await Directory.systemTemp.createTemp('lrdp-preview-');
      try {
        await File(
          '${exchange.path}/项目说明.txt',
        ).writeAsString('这是文件中转站的界面测试文件。');
        await File(
          '${exchange.path}/会议记录.csv',
        ).writeAsString('日期,事项\n2026-10-18,远程协作');
        await Directory('${exchange.path}/远程发来的文件').create();
        unawaited(
          showDialog<void>(
            context: tester.element(find.byType(Scaffold).first),
            builder: (_) =>
                TransferDialog(directory: exchange.path, sharingEnabled: true),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('项目说明.txt'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture('file-transfer');
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
      } finally {
        await exchange.delete(recursive: true);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
