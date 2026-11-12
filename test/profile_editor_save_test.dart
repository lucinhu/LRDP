import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/l10n/app_strings.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/rdp/rdp_session.dart';
import 'package:lrdp/ui/profile_editor.dart';
import 'package:lrdp/ui/theme.dart';
import 'package:lrdp/ui/workspace_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Vault extends Fake implements FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    dynamic aOptions,
    dynamic iOptions,
    dynamic lOptions,
    dynamic mOptions,
    dynamic webOptions,
    dynamic wOptions,
  }) async => null;
}

class _SavingStore extends ProfileStore {
  _SavingStore(super.preferences) : super(vault: _Vault());
  final attempts = <ProfileEditResult>[];
  Completer<void> pending = Completer<void>();

  @override
  Future<void> save(ConnectionProfile p, {String? password}) async {
    attempts.add(ProfileEditResult(p, password ?? '', false));
    await pending.future;
    await super.save(p, password: password);
  }
}

class _Session extends RdpSession {
  _Session(super.profile);
  final passwords = <String>[];

  @override
  Future<void> connect({
    required String password,
    String acceptedFingerprint = '',
  }) async {
    passwords.add(password);
  }
}

void main() {
  Future<ProfileEditResult? Function()> openEditor(
    WidgetTester tester, {
    bool phone = false,
    ConnectionProfile? profile,
    Future<void> Function(ProfileEditResult)? onSave,
    String locale = 'zh-CN',
  }) async {
    tester.view.physicalSize = Size(phone ? 390 : 1200, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ProfileEditResult? result;
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
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await editProfile(
                  context,
                  profile: profile,
                  onSave: onSave,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  String text(WidgetTester tester, Finder field) => tester
      .widget<TextField>(
        find.descendant(of: field, matching: find.byType(TextField)),
      )
      .controller!
      .text;

  Future<void> submit(WidgetTester tester, {bool connect = false}) async {
    final action = connect
        ? find.byKey(const Key('saveAndConnect'))
        : find.byType(OutlinedButton);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pump();
  }

  testWidgets(
    'failed save preserves fields, password, options and new ID for retry',
    (tester) async {
      final attempts = <ProfileEditResult>[];
      var pending = Completer<void>();
      final result = await openEditor(
        tester,
        onSave: (value) {
          attempts.add(value);
          return pending.future;
        },
      );
      await tester.enterText(
        find.byKey(const Key('profileAddress')),
        '192.0.2.10:3390',
      );
      await tester.enterText(field('显示名称（选填）'), 'Workstation');
      await tester.enterText(field('用户名'), 'alice');
      await tester.enterText(field('域（选填）'), 'LAB');
      await tester.enterText(
        find.byKey(const Key('profilePassword')),
        'retry-secret',
      );
      await tester.tap(find.text('安全地记住密码'));
      await tester.tap(find.text('连接偏好'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('分组'));
      await tester.enterText(field('分组'), 'Servers');
      await tester.ensureVisible(find.text('共享剪贴板'));
      await tester.tap(find.text('共享剪贴板'));
      await tester.ensureVisible(find.text('播放远程声音'));
      await tester.tap(find.text('播放远程声音'));
      await tester.ensureVisible(find.text('画质'));
      await tester.tap(find.text('画质'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('省流量'));
      await tester.tap(find.text('省流量'));
      await submit(tester, connect: true);
      expect(attempts, hasLength(1));
      expect(result(), isNull);
      pending.completeError(StateError('vault locked'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileEditor), findsOneWidget);
      expect(find.text('保存失败：Bad state: vault locked'), findsOneWidget);
      expect(
        text(tester, find.byKey(const Key('profileAddress'))),
        '192.0.2.10:3390',
      );
      expect(text(tester, field('显示名称（选填）')), 'Workstation');
      expect(text(tester, field('用户名')), 'alice');
      expect(text(tester, field('域（选填）')), 'LAB');
      expect(
        text(tester, find.byKey(const Key('profilePassword'))),
        'retry-secret',
      );
      expect(text(tester, field('分组')), 'Servers');
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      pending = Completer<void>();
      await submit(tester, connect: true);
      expect(attempts, hasLength(2));
      expect(find.textContaining('vault locked'), findsNothing);
      expect(attempts.last.profile.toJson(), attempts.first.profile.toJson());
      expect(attempts.last.profile.id, isNotEmpty);
      expect(attempts.last.profile.clipboard, isFalse);
      expect(attempts.last.profile.audio, isTrue);
      expect(attempts.last.profile.quality, ConnectionQuality.saveBandwidth);
      expect(attempts.last.password, 'retry-secret');
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ProfileEditor), findsNothing);
      expect(result(), same(attempts.last));
      expect(result()!.connect, isTrue);
    },
  );

  for (final phone in [false, true]) {
    testWidgets(
      '${phone ? 'phone' : 'desktop'} pending save blocks duplicate submit, edits and dismissal',
      (tester) async {
        final attempts = <ProfileEditResult>[];
        final pending = Completer<void>();
        final result = await openEditor(
          tester,
          phone: phone,
          onSave: (value) {
            attempts.add(value);
            return pending.future;
          },
        );
        final address = find.byKey(const Key('profileAddress'));
        await tester.enterText(address, '192.0.2.11');
        final save = find.byType(OutlinedButton);
        await tester.ensureVisible(save);
        final activate = tester.widget<OutlinedButton>(save).onPressed!;
        activate();
        activate();
        await tester.pump();
        // The synchronous guard also rejects activations before the next rebuild.
        expect(attempts, hasLength(1));
        expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull,
        );
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('saveAndConnect')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.byKey(const Key('saveAndConnect')),
          warnIfMissed: false,
        );
        await tester.tap(find.byTooltip('关闭'), warnIfMissed: false);
        await tester.ensureVisible(address);
        await tester.tap(address, warnIfMissed: false);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
        expect(text(tester, address), '192.0.2.11');
        expect(tester.testTextInput.isVisible, isFalse);
        expect(
          tester.widget<ExcludeFocus>(find.byType(ExcludeFocus).last).excluding,
          isTrue,
        );
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        if (!phone) {
          await tester.tapAt(const Offset(8, 8));
          await tester.pump();
        }
        expect(find.byType(ProfileEditor), findsOneWidget);
        expect(attempts, hasLength(1));
        expect(result(), isNull);
        pending.completeError(StateError('try later'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNotNull,
        );
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(ProfileEditor), findsNothing);
        expect(result(), isNull);
      },
    );
  }

  for (final connect in [false, true]) {
    testWidgets(
      'successful async save returns original connect=$connect and existing ID',
      (tester) async {
        final pending = Completer<void>();
        ProfileEditResult? submitted;
        final result = await openEditor(
          tester,
          profile: const ConnectionProfile(
            id: 'existing',
            name: 'Existing',
            host: '192.0.2.12',
          ),
          onSave: (value) {
            submitted = value;
            return pending.future;
          },
        );
        await submit(tester, connect: connect);
        expect(find.byType(ProfileEditor), findsOneWidget);
        expect(result(), isNull);
        pending.complete();
        await tester.pumpAndSettle();
        expect(result(), same(submitted));
        expect(result()!.connect, connect);
        expect(result()!.profile.id, 'existing');
      },
    );

    testWidgets('legacy call without onSave still returns connect=$connect', (
      tester,
    ) async {
      final result = await openEditor(tester);
      await tester.enterText(
        find.byKey(const Key('profileAddress')),
        '192.0.2.13',
      );
      await submit(tester, connect: connect);
      await tester.pumpAndSettle();
      expect(find.byType(ProfileEditor), findsNothing);
      expect(result()!.profile.host, '192.0.2.13');
      expect(result()!.connect, connect);
    });
  }

  testWidgets('save error uses the existing translated message', (
    tester,
  ) async {
    await openEditor(
      tester,
      locale: 'en',
      onSave: (_) async {
        throw StateError('vault locked');
      },
    );
    await tester.enterText(
      find.byKey(const Key('profileAddress')),
      '192.0.2.14',
    );
    await submit(tester);
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save: Bad state: vault locked'),
      findsOneWidget,
    );
    expect(find.byType(ProfileEditor), findsOneWidget);
  });

  testWidgets(
    'validation does not invoke save and disposed saves do not touch the route',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      await openEditor(
        tester,
        onSave: (_) {
          calls++;
          return pending.future;
        },
      );
      await submit(tester);
      expect(calls, 0);
      await tester.enterText(
        find.byKey(const Key('profileAddress')),
        '192.0.2.15',
      );
      await submit(tester);
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      pending.completeError(StateError('late failure'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final importing in [false, true]) {
    testWidgets(
      'workspace ${importing ? 'RDP import' : 'ordinary editor'} saves before pop and connects only after success',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final store = _SavingStore(await SharedPreferences.getInstance());
        addTearDown(store.dispose);
        tester.view.physicalSize = const Size(390, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final sessions = <_Session>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: WorkspaceScreen(
              store: store,
              sessionFactory: (p, _) {
                final editor = find.byType(ProfileEditor);
                if (editor.evaluate().isNotEmpty) {
                  expect(
                    ModalRoute.of(tester.element(editor))!.isCurrent,
                    isFalse,
                    reason: 'Connect only after the editor route is popped',
                  );
                }
                final session = _Session(p);
                sessions.add(session);
                return session;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (importing) {
          final directory = Directory.systemTemp.createTempSync(
            'lrdp-editor-import-',
          );
          addTearDown(() => directory.deleteSync(recursive: true));
          final file = File('${directory.path}/Imported.rdp')
            ..writeAsStringSync(
              'full address:s:192.0.2.20:3390\nusername:s:alice\nredirectclipboard:i:0\n',
            );
          const picker = MethodChannel('plugins.flutter.io/file_selector');
          final messenger = tester.binding.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(picker, (call) async {
            expect(call.method, 'openFile');
            return [file.path];
          });
          addTearDown(() => messenger.setMockMethodCallHandler(picker, null));
          await tester.tap(find.byTooltip('导入 .rdp'));
          await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 5));
            while (find.byType(ProfileEditor).evaluate().isEmpty &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
              await tester.pump();
            }
          });
          await tester.pumpAndSettle();
          expect(find.byType(ProfileEditor), findsOneWidget);
          expect(
            text(tester, find.byKey(const Key('profileAddress'))),
            '192.0.2.20:3390',
          );
        } else {
          await tester.tap(find.text('添加电脑').first);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('profileAddress')),
            '192.0.2.21',
          );
          await tester.enterText(field('用户名'), 'alice');
        }
        await tester.enterText(
          find.byKey(const Key('profilePassword')),
          'temporary-secret',
        );
        await submit(tester, connect: true);
        expect(store.attempts, hasLength(1));
        expect(sessions, isEmpty);
        expect(store.profiles, isEmpty);
        store.pending.completeError(StateError('disk unavailable'));
        await tester.pumpAndSettle();
        expect(find.byType(ProfileEditor), findsOneWidget);
        expect(find.text('保存失败：Bad state: disk unavailable'), findsOneWidget);
        expect(
          text(tester, find.byKey(const Key('profilePassword'))),
          'temporary-secret',
        );
        expect(sessions, isEmpty);
        store.pending = Completer<void>();
        await submit(tester, connect: true);
        expect(store.attempts, hasLength(2));
        expect(store.attempts.last.profile.id, store.attempts.first.profile.id);
        store.pending.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(find.byType(ProfileEditor), findsNothing);
        expect(
          store.attempts,
          hasLength(2),
          reason: 'No second save after the dialog closes',
        );
        expect(store.profiles, hasLength(1));
        expect(sessions, hasLength(1));
        expect(sessions.single.passwords, ['temporary-secret']);
        if (importing) {
          expect(store.profiles.single.name, 'Imported');
          expect(store.profiles.single.clipboard, isFalse);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  }
}
