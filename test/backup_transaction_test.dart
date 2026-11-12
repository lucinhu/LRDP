import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Preferences extends Fake implements SharedPreferences {
  String? saved;
  int writes = 0;
  bool failWrite = false;

  @override
  String? getString(String key) => key == 'profiles.v1' ? saved : null;

  @override
  Future<bool> setString(String key, String value) async {
    expect(key, 'profiles.v1');
    writes++;
    if (failWrite) return false;
    saved = value;
    return true;
  }
}

// Any vault access during an import fails this test: backups must not touch it.
class _UntouchedVault extends Fake implements FlutterSecureStorage {}

ConnectionProfile _profile(String id) => ConnectionProfile(
  id: id,
  name: 'Server $id',
  host: '$id.example',
  username: 'alice',
  rememberPassword: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'imports one batch with one write and one notification, without secrets',
    () async {
      final prefs = _Preferences();
      final store = ProfileStore(prefs, vault: _UntouchedVault());
      addTearDown(store.dispose);
      await store.save(_profile('existing'));
      var notifications = 0;
      store.addListener(() => notifications++);
      prefs.writes = 0;
      final incoming = List.generate(100, (i) => _profile('new$i'));
      final result = await store.importBackup([
        _profile('existing'),
        ...incoming,
      ]);
      expect(result, (imported: 100, skipped: 1));
      expect(prefs.writes, 1);
      expect(notifications, 1);
      expect(store.profiles.map((p) => p.id), [
        'existing',
        ...incoming.map((p) => p.id),
      ]);
      final persisted = (jsonDecode(prefs.saved!) as List)
          .cast<Map<String, dynamic>>();
      expect(persisted, hasLength(101));
      expect(persisted.every((p) => !p.containsKey('password')), isTrue);

      final reloaded = ProfileStore(prefs, vault: _UntouchedVault());
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(
        reloaded.profiles.map((p) => p.id),
        store.profiles.map((p) => p.id),
      );
    },
  );

  test(
    'failed batch publishes nothing and can be retried without partial import',
    () async {
      final prefs = _Preferences();
      final store = ProfileStore(prefs, vault: _UntouchedVault());
      addTearDown(store.dispose);
      await store.save(_profile('existing'));
      final original = prefs.saved;
      var notifications = 0;
      store.addListener(() => notifications++);
      prefs.failWrite = true;
      final incoming = [_profile('first'), _profile('second')];
      await expectLater(store.importBackup(incoming), throwsStateError);
      expect(store.profiles.map((p) => p.id), ['existing']);
      expect(prefs.saved, original);
      expect(notifications, 0);
      prefs.failWrite = false;
      expect(await store.importBackup(incoming), (imported: 2, skipped: 0));
      expect(store.profiles.map((p) => p.id), ['existing', 'first', 'second']);
      expect(notifications, 1);
    },
  );

  test(
    'concurrent imports merge inside the queue and skip-only batches never write',
    () async {
      final prefs = _Preferences();
      final store = ProfileStore(prefs, vault: _UntouchedVault());
      addTearDown(store.dispose);
      final results = await Future.wait([
        store.importBackup([_profile('same')]),
        store.importBackup([_profile('same'), _profile('other')]),
      ]);
      expect(results, [(imported: 1, skipped: 0), (imported: 1, skipped: 1)]);
      expect(store.profiles.map((p) => p.id), ['same', 'other']);
      final before = prefs.writes;
      expect(await store.importBackup([_profile('same')]), (
        imported: 0,
        skipped: 1,
      ));
      expect(prefs.writes, before);
    },
  );
}
