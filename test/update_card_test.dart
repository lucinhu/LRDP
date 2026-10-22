import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lrdp/app.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/l10n/app_strings.dart';
import 'package:lrdp/ui/update_card.dart';
import 'package:lrdp/updates/github_updates.dart';
import 'github_updates_test.dart' show release, asset, feed;

class UpdateVault extends Fake implements FlutterSecureStorage {
  final values = <String, String>{};
  bool locked = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (locked) return Future<String?>.error(StateError('unavailable'));
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

void main() {
  Future<(ProfileStore, SharedPreferences, UpdateVault)> store() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final vault = UpdateVault();
    final result = ProfileStore(preferences, vault: vault);
    addTearDown(result.dispose);
    return (result, preferences, vault);
  }

  Future<void> mount(
    WidgetTester tester,
    ProfileStore store,
    GithubUpdates service, {
    String language = 'zh-CN',
    UpdateTarget target = UpdateTarget.linuxX64,
    Future<bool> Function(Uri)? open,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: AppStrings.localeFor(language),
        localizationsDelegates: const [
          AppStrings.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppStrings.supportedLocales,
        home: Scaffold(
          body: ListView(
            children: [
              UpdateCard(
                store: store,
                updates: service,
                target: target,
                openUrl: open,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'update preferences persist; token is vault-only and never in settings JSON',
    () async {
      final (s, p, v) = await store();
      expect(s.includePreviewUpdates, isTrue);
      expect(await s.githubUpdateToken(), isNull);
      await s.setIncludePreviewUpdates(false);
      await s.setGithubUpdateToken('fixture_secret_token');
      final reloaded = ProfileStore(p, vault: v);
      addTearDown(reloaded.dispose);
      expect(reloaded.includePreviewUpdates, isFalse);
      expect(await reloaded.githubUpdateToken(), 'fixture_secret_token');
      expect(
        jsonEncode({for (final k in p.getKeys()) k: p.get(k)}),
        isNot(contains('fixture_secret_token')),
      );
      await s.setGithubUpdateToken(null);
      expect(s.hasGithubUpdateToken, isFalse);
      expect(v.values, isEmpty);
      expect(await s.githubUpdateToken(), isNull);
    },
  );
  test(
    'locked vault and invalid token do not create saved marker or plaintext fallback',
    () async {
      final (s, p, v) = await store();
      v.locked = true;
      await expectLater(
        s.setGithubUpdateToken('fixture_secret_token'),
        throwsA(isA<StateError>()),
      );
      expect(s.hasGithubUpdateToken, isFalse);
      expect(p.getKeys(), isEmpty);
      await expectLater(
        s.setGithubUpdateToken('fixture\nsecret'),
        throwsArgumentError,
      );
      expect(v.values, isEmpty);
    },
  );
  testWidgets('manual check only, no duplicate requests, no update message', (
    tester,
  ) async {
    final (s, _, _) = await store();
    final pending = Completer<http.Response>();
    var calls = 0;
    final service = GithubUpdates(
      clientFactory: () => MockClient((_) {
        calls++;
        return pending.future;
      }),
    );
    await mount(tester, s, service);
    expect(calls, 0);
    final button = find.byKey(const Key('checkUpdates'));
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(calls, 1);
    pending.complete(
      http.Response(
        jsonEncode([release('v0.1.0-preview.3', preview: true)]),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未发现比当前版本更新的发布。'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(s.includePreviewUpdates, isFalse);
    expect(find.text('未发现比当前版本更新的发布。'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'new version opens notes with correct installer and browser links without secrets',
    (tester) async {
      final (s, _, _) = await store();
      final opened = <Uri>[];
      await mount(
        tester,
        s,
        feed([
          release(
            'v1.0.0',
            assets: [
              asset('v1.0.0', 'lrdp-1.0.0-android-arm64-release.apk'),
              asset('v1.0.0', 'lrdp-1.0.0-linux-x64.AppImage'),
            ],
          ),
        ]),
        target: UpdateTarget.androidArm64,
        open: (url) async {
          opened.add(url);
          return true;
        },
      );
      await tester.tap(find.byKey(const Key('checkUpdates')));
      await tester.pumpAndSettle();
      expect(find.text('Release notes'), findsOneWidget);
      await tester.tap(find.text('下载安装包'));
      await tester.pumpAndSettle();
      expect(opened.single.path, endsWith('android-arm64-release.apk'));
      expect(opened.single.query, isEmpty);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看更新'));
      await tester.pumpAndSettle();
      expect(find.text('Release notes'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'unsupported architecture gets release page, not a wrong installer',
    (tester) async {
      final (s, _, _) = await store();
      await mount(
        tester,
        s,
        feed([
          release(
            'v1.0.0',
            assets: [asset('v1.0.0', 'lrdp-1.0.0-android-arm64-release.apk')],
          ),
        ]),
        target: UpdateTarget.androidX64,
      );
      await tester.tap(find.byKey(const Key('checkUpdates')));
      await tester.pumpAndSettle();
      expect(find.text('下载安装包'), findsNothing);
      expect(find.text('此版本未提供适用于当前系统和架构的安装包，可前往发布页面查看。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    '404 explains private access and permits retry; failed browser exposes copy link',
    (tester) async {
      final (s, _, _) = await store();
      var calls = 0;
      final service = GithubUpdates(
        clientFactory: () => MockClient(
          (_) async => ++calls == 1
              ? http.Response('Not found', 404)
              : http.Response('[]', 200),
        ),
      );
      await mount(tester, s, service, open: (_) async => false);
      await tester.tap(find.byKey(const Key('checkUpdates')));
      await tester.pumpAndSettle();
      expect(find.textContaining('私有仓库需要'), findsOneWidget);
      await tester.tap(find.byKey(const Key('checkUpdates')));
      await tester.pumpAndSettle();
      expect(find.text('此更新通道尚无可用发布。'), findsOneWidget);
      expect(find.textContaining('私有仓库需要'), findsNothing);
      await tester.tap(find.text('查看发布页面'));
      await tester.pumpAndSettle();
      expect(find.text('无法打开浏览器'), findsOneWidget);
      expect(find.text('复制链接'), findsOneWidget);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            expect(
              (call.arguments as Map)['text'],
              GithubUpdates.releasesPage.toString(),
            );
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('复制链接'));
      await tester.pumpAndSettle();
      expect(find.text('无法打开浏览器'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'token dialog saves, reopens blank, removes, and reports secure storage failure',
    (tester) async {
      final (s, _, v) = await store();
      await mount(tester, s, feed([]));
      Future<void> open() async {
        await tester.tap(find.text('GitHub 访问令牌'));
        await tester.pumpAndSettle();
      }

      await open();
      await tester.enterText(
        find.byKey(const Key('githubUpdateToken')),
        'fixture_secret_token',
      );
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(s.hasGithubUpdateToken, isTrue);
      await open();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('githubUpdateToken')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.tap(find.text('移除令牌'));
      await tester.pumpAndSettle();
      expect(v.values, isEmpty);
      v.locked = true;
      await open();
      await tester.enterText(
        find.byKey(const Key('githubUpdateToken')),
        'fixture_secret_token',
      );
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('令牌未能保存，请检查系统安全存储后重试。'), findsOneWidget);
      expect(s.hasGithubUpdateToken, isFalse);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final (language, check, token, later) in [
    ('zh-CN', '检查更新', 'GitHub 访问令牌', '稍后'),
    ('zh-TW', '檢查更新', 'GitHub 存取權杖', '稍後'),
    ('en', 'Check for updates', 'GitHub access token', 'Later'),
  ]) {
    testWidgets(
      'small phone at 200 percent supports update and token dialogs: $language',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final (s, _, _) = await store();
        await mount(tester, s, feed([release('v1.0.0')]), language: language);
        await tester.ensureVisible(find.text(check));
        await tester.pumpAndSettle();
        await tester.tap(find.text(check));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text(later));
        await tester.pumpAndSettle();
        await tester.tap(find.text(later));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(token));
        await tester.pumpAndSettle();
        await tester.tap(find.text(token));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('githubUpdateToken')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final size in [const Size(390, 844), const Size(1280, 840)]) {
    testWidgets('settings include update entry at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (s, _, _) = await store();
      await tester.pumpWidget(LrdpApp(store: s));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('updateCard')),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('workspaceSettings')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(find.byKey(const Key('checkUpdates')));
      await tester.pumpAndSettle();
      expect(find.text('检查更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
