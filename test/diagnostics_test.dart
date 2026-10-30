import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/app_version.dart';
import 'package:lrdp/data/diagnostics.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/l10n/app_strings.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/ui/diagnostics_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _settings = <String, Object?>{
  'themeMode': 'system',
  'frameRateLimit': 60,
  'imageScaling': 'smooth',
  'pointerSpeed': 100,
  'openFullscreen': true,
  'useSystemColors': false,
  'includePreviewUpdates': true,
};

const _expected =
    'LRDP 诊断信息\n'
    '版本: v9.9.9-test\n'
    '平台: linux 6.8.0-test\n'
    '语言: zh-CN\n'
    '连接配置: 3\n'
    '设置:\n'
    '  frameRateLimit: 60\n'
    '  imageScaling: smooth\n'
    '  includePreviewUpdates: true\n'
    '  openFullscreen: true\n'
    '  pointerSpeed: 100\n'
    '  themeMode: system\n'
    '  useSystemColors: false';

String _build([Map<String, Object?> settings = _settings]) => buildDiagnostics(
  appTag: 'v9.9.9-test',
  platform: 'linux 6.8.0-test',
  locale: 'zh-CN',
  profileCount: 3,
  settings: settings,
);

Future<ProfileStore> _store([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  final store = ProfileStore(await SharedPreferences.getInstance());
  await store.load();
  return store;
}

Future<void> _openSheet(WidgetTester tester, ProfileStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        AppStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showDiagnosticsSheet(context, store),
              child: const Text('打开诊断'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开诊断'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildDiagnostics', () {
    test('formats a stable report with sorted settings', () {
      expect(_build(), _expected);
      expect(_build(), _expected);
    });

    test('does not depend on settings insertion order', () {
      final reversed = <String, Object?>{};
      for (final key in _settings.keys.toList().reversed) {
        reversed[key] = _settings[key];
      }
      expect(_build(reversed), _expected);
    });

    test('contains no connection or credential data', () {
      final report = _build().toLowerCase();
      for (final forbidden in [
        'password',
        '密码',
        'username',
        'domain',
        'fingerprint',
        'token',
        '192.0.2.77',
        'alice',
        'corp',
      ]) {
        expect(
          report.contains(forbidden),
          isFalse,
          reason: '"$forbidden" must not appear in the report',
        );
      }
    });

    test('folds injected line breaks into one field line', () {
      final report = buildDiagnostics(
        appTag: 'v1',
        platform: 'linux',
        locale: 'zh-CN',
        profileCount: 0,
        settings: const {'themeMode': 'system\r\nhost: 192.0.2.77'},
      );
      expect(report.split('\n').length, 7);
      expect(report, contains('  themeMode: system host: 192.0.2.77'));
    });
  });

  group('collectDiagnostics', () {
    test('reports app, platform, language, and settings', () async {
      final store = await _store({'language': 'zh-CN'});
      addTearDown(store.dispose);
      final report = await collectDiagnostics(store);

      expect(report.split('\n').first, 'LRDP 诊断信息');
      expect(report, contains('版本: $appReleaseTag'));
      expect(
        report,
        contains(
          '平台: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}',
        ),
      );
      expect(report, contains('语言: 简体中文'));
      expect(report, contains('连接配置: 0'));
      for (final key in _settings.keys) {
        expect(report, contains('  $key: '));
      }
      expect(report, contains('  themeMode: system'));
      expect(report, contains('  frameRateLimit: 0'));
      expect(report, contains('  imageScaling: smooth'));
      expect(report, contains('  pointerSpeed: 100'));
      expect(report, contains('  openFullscreen: true'));
      expect(report, contains('  useSystemColors: true'));
      expect(report, contains('  includePreviewUpdates: true'));
    });

    test('never leaks saved profile fields', () async {
      final store = await _store();
      addTearDown(store.dispose);
      await store.save(
        const ConnectionProfile(
          id: 'support-secret',
          name: '财务服务器',
          host: '192.0.2.77',
          username: 'alice',
          domain: 'CORP',
        ),
      );
      final report = await collectDiagnostics(store);

      expect(report, contains('连接配置: 1'));
      for (final secret in [
        'support-secret',
        '财务服务器',
        '192.0.2.77',
        'alice',
        'CORP',
      ]) {
        expect(
          report.contains(secret),
          isFalse,
          reason: '"$secret" must not appear in the report',
        );
      }
    });
  });

  group('showDiagnosticsSheet', () {
    testWidgets('copies the report and confirms it', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = await _store();
      addTearDown(store.dispose);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String? copied;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final report = await collectDiagnostics(store);
      await _openSheet(tester, store);

      expect(find.text('复制诊断信息'), findsOneWidget);
      expect(find.text('仅包含版本、平台与显示设置，不含连接地址和凭据。'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        report,
      );

      await tester.tap(find.widgetWithText(FilledButton, '复制诊断信息'));
      await tester.pumpAndSettle();

      expect(copied, report);
      expect(copied, contains('LRDP 诊断信息'));
      expect(copied, contains(appReleaseTag));
      expect(find.text('诊断信息已复制'), findsOneWidget);

      // Let the confirmation timer elapse so no fake timer outlives the test.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('reports a clipboard failure', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = await _store();
      addTearDown(store.dispose);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(
            code: 'unavailable',
            message: 'clipboard unavailable',
          );
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await _openSheet(tester, store);
      await tester.tap(find.widgetWithText(FilledButton, '复制诊断信息'));
      await tester.pumpAndSettle();

      expect(find.textContaining('复制失败：'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
