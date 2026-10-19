import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/app.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';

void main() {
  Future<ProfileStore> store() async {
    SharedPreferences.setMockInitialValues({});
    final result = ProfileStore(await SharedPreferences.getInstance());
    await result.load();
    return result;
  }

  testWidgets(
    'phone group filter recovers when its last computer changes group',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final profiles = await store();
      const first = ConnectionProfile(
        id: 'a',
        name: '电脑 A',
        host: '192.0.2.1',
        group: '工作',
      );
      const second = ConnectionProfile(
        id: 'b',
        name: '电脑 B',
        host: '192.0.2.2',
        group: '个人',
      );
      await profiles.save(first);
      await profiles.save(second);
      await tester.pumpWidget(LrdpApp(store: profiles));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '工作'));
      await tester.pumpAndSettle();
      expect(find.text('电脑 B'), findsNothing);
      await profiles.update(first.copyWith(group: '个人'));
      await tester.pumpAndSettle();
      expect(find.text('电脑 A'), findsOneWidget);
      expect(find.text('电脑 B'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('desktop workspace, save profile and filter connections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final profiles = await store();
    await tester.pumpWidget(LrdpApp(store: profiles));
    await tester.pumpAndSettle();
    expect(find.text('连接管理'), findsOneWidget);
    expect(find.text('快速连接'), findsOneWidget);
    await tester.tap(find.text('添加电脑').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profileAddress')),
      '192.168.1.10:3390',
    );
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(profiles.profiles.single.port, 3390);
    expect(profiles.profiles.single.host, '192.168.1.10');
    expect(find.text('192.168.1.10:3390'), findsOneWidget);
    final search = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '搜索名称、地址或用户名…',
    );
    await tester.enterText(search, 'not-found');
    await tester.pumpAndSettle();
    expect(find.text('没有找到匹配的电脑'), findsOneWidget);
    await tester.tap(find.text('查看全部连接'));
    await tester.pumpAndSettle();
    expect(find.text('192.168.1.10:3390'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final size in [
    const Size(390, 844),
    const Size(320, 568),
    const Size(844, 390),
    const Size(800, 600),
  ]) {
    testWidgets('responsive layout at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final profiles = await store();
      await profiles.save(
        const ConnectionProfile(id: 'phone', name: '测试电脑', host: '10.0.0.1'),
      );
      await tester.pumpWidget(LrdpApp(store: profiles));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (size == const Size(800, 600)) {
        await tester.tap(find.byTooltip('导航'));
        await tester.pumpAndSettle();
        expect(find.text('LRDP'), findsOneWidget);
      } else {
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.text('测试电脑'), findsOneWidget);
        await tester.tap(find.text('收藏'));
        await tester.pumpAndSettle();
        expect(find.text('测试电脑'), findsNothing);
        expect(find.text('暂无收藏'), findsOneWidget);
        await tester.tap(find.text('设置').last);
        await tester.pumpAndSettle();
        expect(find.text('深色外观'), findsOneWidget);
        await tester.tap(find.text('电脑').last);
        await tester.pumpAndSettle();
        expect(find.text('测试电脑'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
