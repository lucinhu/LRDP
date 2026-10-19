import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:lrdp/l10n/app_strings.dart';
import 'package:lrdp/l10n/messages.dart';
import 'package:lrdp/ui/profile_editor.dart';
import 'package:lrdp/ui/theme.dart';

void main() {
  for (final locale in ['zh-CN', 'zh-TW', 'en']) {
    for (final width in [390.0, 1200.0]) {
      testWidgets(
        'expanded preference labels are inside the clip: $locale $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 1800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final messages = localizedMessages[locale]!;
          await tester.pumpWidget(
            MaterialApp(
              locale: AppStrings.localeFor(locale),
              supportedLocales: AppStrings.supportedLocales,
              localizationsDelegates: const [
                AppStrings.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: appTheme(Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Scaffold(body: ProfileEditor()),
            ),
          );
          await tester.pumpAndSettle();
          final title = find.text(messages['连接偏好']!);
          await tester.ensureVisible(title);
          await tester.tap(title);
          await tester.pumpAndSettle();
          final group = find.widgetWithText(TextFormField, messages['分组']!);
          await tester.ensureVisible(group);
          await tester.tap(group);
          await tester.pumpAndSettle();
          for (final source in ['远程分辨率', '分组']) {
            final label = find.text(messages[source]!);
            await tester.ensureVisible(label);
            await tester.pumpAndSettle();
            final render = tester.renderObject<RenderBox>(label);
            final bounds = MatrixUtils.transformRect(
              render.getTransformTo(null),
              Offset.zero & render.size,
            );
            RenderObject? ancestor = render.parent;
            while (ancestor != null && ancestor is! RenderClipRect) {
              ancestor = ancestor.parent;
            }
            expect(ancestor, isA<RenderClipRect>());
            final clip = ancestor! as RenderClipRect;
            final clipBounds = MatrixUtils.transformRect(
              clip.getTransformTo(null),
              Offset.zero & clip.size,
            );
            expect(bounds.top, greaterThanOrEqualTo(clipBounds.top));
            expect(bounds.left, greaterThanOrEqualTo(clipBounds.left));
            expect(bounds.bottom, lessThanOrEqualTo(clipBounds.bottom));
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('phone save stays reachable above the keyboard with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewInsets);
    ProfileEditResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await editProfile(context);
              },
              child: const Text('打开表单'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开表单'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('profileAddress')),
      '192.0.2.10:3390',
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    final save = find.widgetWithText(OutlinedButton, '保存连接');
    expect(tester.getRect(save).bottom, lessThanOrEqualTo(318));
    expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(result!.profile.host, '192.0.2.10');
    expect(result!.profile.port, 3390);
    expect(result!.profile.automaticResolution, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final scale in [1.0, 1.4]) {
    testWidgets(
      'landscape IME keeps the field and save actions usable at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(914, 411);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(
          top: 24,
          bottom: 20,
          left: 40,
        );
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewInsets);
        ProfileEditResult? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await editProfile(context);
                  },
                  child: const Text('打开表单'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开表单'));
        await tester.pumpAndSettle();
        final address = find.byKey(const Key('profileAddress'));
        await tester.enterText(address, '192.0.2.20');
        tester.view.viewInsets = const FakeViewPadding(bottom: 245);
        await tester.pumpAndSettle();
        final save = find.widgetWithText(OutlinedButton, '保存连接');
        final connect = find.byKey(const Key('saveAndConnect'));
        for (final action in [save, connect]) {
          expect(action.hitTestable(), findsOneWidget);
          expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(action).bottom, lessThanOrEqualTo(166));
        }
        await tester.ensureVisible(address);
        final editable = find.descendant(
          of: address,
          matching: find.byType(EditableText),
        );
        final inputCenter = tester.getCenter(editable);
        expect(
          inputCenter.dy,
          greaterThanOrEqualTo(tester.getRect(save).bottom),
        );
        expect(inputCenter.dy, lessThan(166));
        expect(tester.takeException(), isNull);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(result?.profile.host, '192.0.2.20');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('small-screen connection editor and advanced preferences fit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: const Scaffold(body: ProfileEditor()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('连接偏好'));
    await tester.tap(find.text('连接偏好'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('文件传输'));
    await tester.tap(find.text('文件传输'));
    await tester.pumpAndSettle();
    expect(find.text('使用文件中转站'), findsOneWidget);
    await tester.ensureVisible(find.text('播放远程声音'));
    await tester.tap(find.text('播放远程声音'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('保存连接'));
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入主机名或 IP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
