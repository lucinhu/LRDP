import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/app.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/l10n/app_strings.dart';
import 'package:lrdp/l10n/messages.dart';

void main() {
  test('catalogs are complete and preserve every positional placeholder', () {
    final catalogs = [
      for (final language in ['zh-CN', 'zh-TW', 'en'])
        (jsonDecode(File('assets/l10n/$language.json').readAsStringSync())
                as Map)
            .cast<String, String>(),
    ];
    final slots = RegExp(r'\{\d+\}');
    for (final catalog in catalogs) {
      expect(catalog.keys.toSet(), catalogs.first.keys.toSet());
      for (final entry in catalog.entries) {
        expect(entry.value, isNotEmpty, reason: entry.key);
        expect(
          slots.allMatches(entry.value).map((m) => m[0]).toList()..sort(),
          slots.allMatches(entry.key).map((m) => m[0]).toList()..sort(),
          reason: entry.key,
        );
      }
    }
    for (final language in ['zh-CN', 'zh-TW', 'en']) {
      expect(
        localizedMessages[language],
        jsonDecode(File('assets/l10n/$language.json').readAsStringSync()),
      );
    }
    final strings = AppStrings(const Locale('en'), catalogs.last);
    expect(strings.text('删除「{0}」？', ['设置{1}']), 'Delete “设置{1}”?');
    expect(
      AppStrings.resolve([
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ], []),
      const Locale('zh', 'TW'),
    );
    expect(
      AppStrings.resolve([const Locale('zh', 'SG')], []),
      const Locale('zh', 'CN'),
    );
    expect(AppStrings.resolve([const Locale('de')], []), const Locale('en'));
  });

  testWidgets(
    'system language and saved override switch the open editor in place',
    (tester) async {
      final dispatcher = tester.binding.platformDispatcher;
      dispatcher.localesTestValue = [const Locale('en', 'US')];
      addTearDown(
        () => dispatcher.localesTestValue = [const Locale('zh', 'CN')],
      );
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ProfileStore(preferences);
      await tester.pumpWidget(LrdpApp(store: store));
      await tester.pumpAndSettle();
      expect(find.text('Quick connect'), findsOneWidget);
      await tester.tap(find.text('Add computer').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('profileAddress')),
        'example.com:3391',
      );
      await store.setLanguage('zh-TW');
      await tester.pumpAndSettle();
      expect(find.text('儲存連線'), findsOneWidget);
      final field = tester.widget<TextFormField>(
        find.byKey(const Key('profileAddress')),
      );
      expect(field.controller!.text, 'example.com:3391');
      expect(ProfileStore(preferences).language, 'zh-TW');
      await store.setLanguage('zh-CN');
      await tester.pumpAndSettle();
      expect(find.text('保存连接'), findsOneWidget);
      await store.setLanguage('system');
      await tester.pumpAndSettle();
      expect(find.text('Save connection'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    },
  );
}
