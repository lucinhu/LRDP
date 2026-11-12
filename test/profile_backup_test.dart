import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/data/profile_backup.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/ui/backup_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryVault extends Fake implements FlutterSecureStorage {
  final values = <String, String>{};
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(values[key]);
      case #write:
        values[key!] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

ConnectionProfile _profile({
  String id = 'p1',
  String name = '办公室电脑',
  String host = '192.0.2.10',
  int port = 3389,
  String username = 'alice',
}) => ConnectionProfile(
  id: id,
  name: name,
  host: host,
  port: port,
  username: username,
);

Widget _host(
  ProfileStore store, {
  Future<String?> Function(String suggestedName)? savePath,
  Future<String?> Function()? openPath,
}) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showBackupDialog(
            context,
            store,
            savePath: savePath,
            openPath: openPath,
          ),
          child: const Text('打开配置备份'),
        ),
      ),
    ),
  ),
);

/// Drives both the widget tree and real file I/O, which only advances while
/// the test runs inside [WidgetTester.runAsync].
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
  }
}

Future<void> _drainSnackBars(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  group('backup document', () {
    test('round-trips every profile field and never writes secrets', () {
      final profile = ConnectionProfile(
        id: 'full',
        name: 'Office',
        host: 'EXAMPLE.com',
        port: 3390,
        username: 'Alice',
        domain: 'CORP',
        group: '工作',
        favorite: true,
        width: 1920,
        height: 1080,
        automaticResolution: false,
        clipboard: false,
        audio: true,
        quality: ConnectionQuality.sharpText,
        autoReconnect: false,
        fileTransfer: true,
        sharedDirectory: '/srv/share',
        nla: false,
        rememberPassword: true,
        lastConnectedAt: DateTime.utc(2025, 2, 3, 4, 5, 6),
      );

      final text = encodeBackup([profile]);
      final envelope = jsonDecode(text) as Map<String, dynamic>;
      expect(envelope['format'], backupFormat);
      expect(envelope['version'], backupVersion);
      final fields =
          (envelope['profiles'] as List).single as Map<String, dynamic>;
      expect(fields, profile.toJson());
      expect(fields.containsKey('password'), isFalse);
      expect(fields.containsKey('certificateFingerprint'), isFalse);
      expect(text, isNot(contains('hunter2-secret')));
      // A backup must stay deterministic for the same input.
      expect(encodeBackup([profile]), text);

      final parsed = decodeBackup(text);
      expect(parsed.error, isNull);
      expect(parsed.isSuccess, isTrue);
      expect(parsed.profiles.single.toJson(), profile.toJson());
      // A byte-order mark from Windows editors is tolerated, not fatal.
      expect(decodeBackup('\ufeff$text').isSuccess, isTrue);
    });

    test('rejects malformed JSON and non-envelope documents', () {
      expect(decodeBackup('{not json').error, BackupError.invalidJson);
      expect(decodeBackup('[]').error, BackupError.invalidFormat);
      expect(
        decodeBackup(jsonEncode({'format': 'other', 'version': 1})).error,
        BackupError.invalidFormat,
      );
      expect(
        decodeBackup(
          jsonEncode({'format': backupFormat, 'version': '1'}),
        ).error,
        BackupError.invalidFormat,
      );
      expect(
        decodeBackup(jsonEncode({'format': backupFormat, 'version': 1})).error,
        BackupError.invalidFormat,
      );
    });

    test('rejects versions it cannot migrate', () {
      final result = decodeBackup(
        jsonEncode({'format': backupFormat, 'version': 2, 'profiles': []}),
      );
      expect(result.error, BackupError.unsupportedVersion);
      expect(result.profiles, isEmpty);
    });

    test('rejects empty backups and invalid profile entries', () {
      expect(
        decodeBackup(
          jsonEncode({'format': backupFormat, 'version': 1, 'profiles': []}),
        ).error,
        BackupError.empty,
      );
      expect(
        decodeBackup(
          jsonEncode({
            'format': backupFormat,
            'version': 1,
            'profiles': [
              {'id': 'missing-host'},
            ],
          }),
        ).error,
        BackupError.invalidFormat,
      );
      expect(
        decodeBackup(
          jsonEncode({
            'format': backupFormat,
            'version': 1,
            'profiles': [
              {'id': 'bad-host', 'name': 'bad', 'host': 'not a host'},
            ],
          }),
        ).error,
        BackupError.invalidFormat,
      );
    });

    test('round-trips accounts on the same endpoint in different domains', () {
      final profiles = [
        _profile(id: 'a').copyWith(domain: 'CORP_A'),
        _profile(id: 'b').copyWith(domain: 'CORP_B'),
        _profile(id: 'local'),
      ];
      final result = decodeBackup(encodeBackup(profiles));
      expect(result.error, isNull);
      expect(result.profiles.map((p) => p.domain), ['CORP_A', 'CORP_B', '']);
    });

    test('rejects duplicate domain accounts regardless of case', () {
      final text = encodeBackup([
        _profile(
          id: 'a',
          host: 'Office',
          username: 'Alice',
        ).copyWith(domain: 'CORP'),
        _profile(
          id: 'b',
          host: 'office',
          username: 'alice',
        ).copyWith(domain: 'corp'),
      ]);
      expect(decodeBackup(text).error, BackupError.invalidFormat);
    });

    test('rejects the same account listed twice inside one file', () {
      final text = encodeBackup([
        _profile(id: 'a', host: 'Office.Example', username: 'Alice'),
        _profile(id: 'b', host: 'office.example', username: 'alice'),
      ]);
      expect(decodeBackup(text).error, BackupError.invalidFormat);
    });
  });

  group('mergeBackup', () {
    test('skips endpoints already configured and keeps incoming order', () {
      final merged = mergeBackup(
        existing: [_profile(id: 'e1', host: '10.0.0.5', username: 'Bob')],
        incoming: [
          _profile(id: 'i1', name: '重复', host: '10.0.0.5', username: 'bOB'),
          _profile(id: 'i2', name: '实验室', host: '10.0.0.7', username: 'carol'),
          _profile(
            id: 'i3',
            name: '实验室 2',
            host: '10.0.0.7',
            port: 3390,
            username: 'carol',
          ),
        ],
      );
      expect(merged.imported, 2);
      expect(merged.skipped, 1);
      expect(merged.imported, merged.profiles.length);
      expect(merged.profiles.map((p) => p.name), ['实验室', '实验室 2']);
      expect(merged.profiles.map((p) => p.id), ['i2', 'i3']);
    });

    test('keeps different domains but skips the same domain account', () {
      final merged = mergeBackup(
        existing: [_profile(id: 'old').copyWith(domain: 'CORP_A')],
        incoming: [
          _profile(
            id: 'duplicate',
            username: 'ALICE',
          ).copyWith(domain: 'corp_a'),
          _profile(id: 'other').copyWith(domain: 'CORP_B'),
          _profile(id: 'local'),
        ],
      );
      expect(merged.imported, 2);
      expect(merged.skipped, 1);
      expect(merged.profiles.map((p) => p.domain), ['CORP_B', '']);
    });

    test('skips duplicates inside the incoming batch', () {
      final merged = mergeBackup(
        existing: const [],
        incoming: [
          _profile(id: 'i1', name: 'A', host: 'alpha', username: 'u'),
          _profile(id: 'i2', name: 'B', host: 'ALPHA', username: 'U'),
          _profile(id: 'i3', name: 'C', host: 'beta', username: 'u'),
        ],
      );
      expect(merged.imported, 2);
      expect(merged.skipped, 1);
      expect(merged.profiles.map((p) => p.name), ['A', 'C']);
    });

    test('generates a unique fresh id when an incoming id is taken', () {
      final merged = mergeBackup(
        existing: [
          _profile(id: 'shared', host: 'old'),
          _profile(id: 'shared-import-1', host: 'older'),
        ],
        incoming: [
          _profile(id: 'shared', name: 'A', host: 'alpha', username: 'u'),
          _profile(
            id: 'shared-import-2',
            name: 'B',
            host: 'beta',
            username: 'u',
          ),
          _profile(id: 'free', name: 'C', host: 'gamma', username: 'u'),
        ],
      );
      expect(merged.imported, 3);
      expect(merged.skipped, 0);
      // 'shared' -> next free suffix; the incoming id itself then collides with
      // the id generated for the earlier profile and is renamed again.
      expect(merged.profiles.map((p) => p.id), [
        'shared-import-2',
        'shared-import-2-import-1',
        'free',
      ]);
      expect(merged.profiles.map((p) => p.name), ['A', 'B', 'C']);
    });

    test('preserves every copied field when re-identifying a profile', () {
      final original = ConnectionProfile(
        id: 'taken',
        name: 'Meeting',
        host: 'meeting.example',
        port: 3391,
        username: 'alice',
        domain: 'CORP',
        group: '工作',
        favorite: true,
        width: 1600,
        height: 900,
        automaticResolution: false,
        clipboard: false,
        audio: true,
        quality: ConnectionQuality.saveBandwidth,
        autoReconnect: false,
        fileTransfer: true,
        sharedDirectory: '/srv/share',
        nla: false,
        rememberPassword: true,
        lastConnectedAt: DateTime.utc(2025, 3, 4, 5, 6, 7),
      );
      final merged = mergeBackup(
        existing: [_profile(id: 'taken', host: 'other')],
        incoming: [original],
      );
      final imported = merged.profiles.single;
      expect(imported.id, 'taken-import-1');
      expect(imported.toJson(), {...original.toJson(), 'id': 'taken-import-1'});
    });

    test('imports everything when there is nothing on this device yet', () {
      final merged = mergeBackup(
        existing: const [],
        incoming: [
          _profile(id: 'a', host: 'alpha', username: 'u'),
          _profile(id: 'b', host: 'beta', username: 'u'),
        ],
      );
      expect(merged.imported, 2);
      expect(merged.skipped, 0);
      expect(merged.profiles.map((p) => p.id), ['a', 'b']);
    });
  });

  group('backup dialog', () {
    testWidgets('export writes the envelope without stored passwords', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore(
        await SharedPreferences.getInstance(),
        vault: _MemoryVault(),
      );
      addTearDown(store.dispose);
      await store.save(
        const ConnectionProfile(
          id: 'p1',
          name: 'Office',
          host: '192.0.2.10',
          username: 'alice',
          rememberPassword: true,
        ),
        password: 'hunter2-secret',
      );

      late Directory directory;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'lrdp-backup-export-',
        );
      });
      addTearDown(() => directory.delete(recursive: true));
      final target = '${directory.path}/export.json';
      String? suggested;
      var picks = 0;
      await tester.pumpWidget(
        _host(
          store,
          savePath: (name) async {
            picks++;
            suggested = name;
            return target;
          },
        ),
      );
      await tester.tap(find.text('打开配置备份'));
      await tester.pumpAndSettle();
      expect(find.text('配置备份'), findsOneWidget);
      expect(find.text('备份包含所有连接配置，不含密码和证书指纹。'), findsOneWidget);

      var exported = '';
      await tester.runAsync(() async {
        await tester.tap(find.text('导出配置备份'));
        await _pumpUntil(
          tester,
          () => find.text('已导出 1 个连接').evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 300));
        if (File(target).existsSync()) {
          exported = await File(target).readAsString();
        }
      });

      expect(picks, 1);
      expect(suggested, backupSuggestedFileName);
      expect(find.text('已导出 1 个连接'), findsOneWidget);
      final envelope = jsonDecode(exported) as Map<String, dynamic>;
      expect(envelope['format'], backupFormat);
      expect(envelope['version'], backupVersion);
      final fields =
          (envelope['profiles'] as List).single as Map<String, dynamic>;
      expect(fields.containsKey('password'), isFalse);
      expect(fields.containsKey('certificateFingerprint'), isFalse);
      expect(exported, isNot(contains('hunter2-secret')));
      await _drainSnackBars(tester);
    });

    testWidgets('export rejects an oversized document before choosing a file', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.save(_profile(name: 'x' * backupMaxBytes));
      var picks = 0;
      await tester.pumpWidget(
        _host(
          store,
          savePath: (_) async {
            picks++;
            return null;
          },
        ),
      );
      await tester.tap(find.text('打开配置备份'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出配置备份'));
      await tester.pumpAndSettle();
      expect(find.text('备份文件不能大于 8 MiB'), findsOneWidget);
      expect(picks, 0);
      await _drainSnackBars(tester);
    });

    testWidgets(
      'export of an empty profile list explains nothing was written',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final store = ProfileStore(await SharedPreferences.getInstance());
        addTearDown(store.dispose);
        await store.load();
        var picks = 0;
        await tester.pumpWidget(
          _host(
            store,
            savePath: (name) async {
              picks++;
              return null;
            },
          ),
        );
        await tester.tap(find.text('打开配置备份'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('导出配置备份'));
        await tester.pumpAndSettle();
        expect(find.text('备份文件中没有连接'), findsOneWidget);
        expect(picks, 0);
        await _drainSnackBars(tester);

        // Closing the dialog without choosing an action does nothing.
        await tester.tap(find.text('打开配置备份'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.text('配置备份'), findsNothing);
        expect(picks, 0);
      },
    );

    testWidgets('import saves new profiles and skips duplicates', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = ProfileStore(prefs);
      addTearDown(store.dispose);
      await store.load();
      await store.save(
        const ConnectionProfile(
          id: 'existing',
          name: '现有连接',
          host: '10.0.0.5',
          username: 'bob',
        ),
      );
      late Directory directory;
      late String backupPath;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp(
          'lrdp-backup-import-',
        );
        backupPath = '${directory.path}/backup.json';
        await File(backupPath).writeAsString(
          encodeBackup([
            const ConnectionProfile(
              id: 'duplicate',
              name: '重复连接',
              host: '10.0.0.5',
              username: 'BOB',
            ),
            const ConnectionProfile(
              id: 'existing',
              name: '新服务器',
              host: '10.0.0.9',
              username: 'carol',
            ),
          ]),
        );
      });
      addTearDown(() => directory.delete(recursive: true));
      await tester.pumpWidget(_host(store, openPath: () async => backupPath));
      await tester.tap(find.text('打开配置备份'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('导入配置备份'));
        await _pumpUntil(
          tester,
          () => find.text('已导入 1 个连接，跳过 1 个重复连接').evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 300));
      });

      expect(find.text('已导入 1 个连接，跳过 1 个重复连接'), findsOneWidget);
      expect(store.profiles.length, 2);
      final imported = store.profiles.firstWhere((p) => p.name == '新服务器');
      expect(imported.id, 'existing-import-1');
      expect(store.profiles.map((p) => p.name), ['现有连接', '新服务器']);
      expect(prefs.getString('profiles.v1'), contains('新服务器'));
      expect(prefs.getString('profiles.v1'), isNot(contains('重复连接')));
      await _drainSnackBars(tester);
    });

    for (final oversized in [false, true]) {
      testWidgets('backup file size boundary: oversized=$oversized', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final store = ProfileStore(await SharedPreferences.getInstance());
        addTearDown(store.dispose);
        await store.save(_profile(id: 'existing'));
        final snapshot = store.profiles.map((p) => p.toJson()).toList();
        late Directory directory;
        late String path;
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp(
            'lrdp-backup-limit-',
          );
          path = '${directory.path}/backup.json';
          if (oversized) {
            final handle = await File(path).open(mode: FileMode.write);
            await handle.truncate(backupMaxBytes + 1);
            await handle.close();
          } else {
            final data = utf8.encode(
              encodeBackup([_profile(id: 'new', host: 'new.example')]),
            );
            final bytes = Uint8List(backupMaxBytes)
              ..fillRange(0, backupMaxBytes, 32)
              ..setRange(0, data.length, data);
            await File(path).writeAsBytes(bytes);
          }
        });
        addTearDown(() => directory.delete(recursive: true));
        await tester.pumpWidget(_host(store, openPath: () async => path));
        await tester.tap(find.text('打开配置备份'));
        await tester.pumpAndSettle();
        final expected = oversized ? '备份文件不能大于 8 MiB' : '已导入 1 个连接，跳过 0 个重复连接';
        await tester.runAsync(() async {
          await tester.tap(find.text('导入配置备份'));
          await _pumpUntil(
            tester,
            () => find.text(expected).evaluate().isNotEmpty,
          );
          await tester.pump(const Duration(milliseconds: 300));
        });
        expect(find.text(expected), findsOneWidget);
        if (oversized) {
          expect(store.profiles.map((p) => p.toJson()), snapshot);
        } else {
          expect(store.profiles.map((p) => p.id), ['existing', 'new']);
        }
        await _drainSnackBars(tester);
      });
    }

    testWidgets('import reports a malformed backup without changing profiles', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.load();
      late Directory directory;
      late String backupPath;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('lrdp-backup-bad-');
        backupPath = '${directory.path}/broken.json';
        await File(backupPath).writeAsString('{not a backup');
      });
      addTearDown(() => directory.delete(recursive: true));
      await tester.pumpWidget(_host(store, openPath: () async => backupPath));
      await tester.tap(find.text('打开配置备份'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('导入配置备份'));
        await _pumpUntil(
          tester,
          () => find.text('备份文件格式不正确').evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 300));
      });

      expect(find.text('备份文件格式不正确'), findsOneWidget);
      expect(store.profiles, isEmpty);
      await _drainSnackBars(tester);
    });
  });
}
