import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/models/connection_profile.dart';
import 'package:lrdp/models/remote_input_mode.dart';

class MemoryVault extends Fake implements FlutterSecureStorage {
  final values = <String, String>{};
  bool locked = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(values[key]);
      case #write:
        if (locked) return Future<void>.error(StateError('vault locked'));
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
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'input mode defaults safely and survives reload independently of profiles',
    () async {
      SharedPreferences.setMockInitialValues({'remoteInputMode': 'unknown'});
      final preferences = await SharedPreferences.getInstance();
      final store = ProfileStore(preferences);
      expect(store.remoteInputMode, RemoteInputMode.keyboard);
      for (final mode in RemoteInputMode.values) {
        await store.setRemoteInputMode(mode);
        expect(ProfileStore(preferences).remoteInputMode, mode);
      }
      expect(preferences.getKeys(), {'remoteInputMode'});
      expect(preferences.getString('profiles.v1'), isNull);
      store.dispose();
    },
  );
  test('profile metadata survives reload without a plaintext secret', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ProfileStore(prefs);
    await store.save(
      const ConnectionProfile(id: '1', name: 'Office', host: '10.0.0.1'),
      password: 'never-persist-me',
    );
    expect(prefs.getString('profiles.v1'), isNot(contains('never-persist-me')));
    final reloaded = ProfileStore(prefs);
    await reloaded.load();
    expect(reloaded.profiles.single.name, 'Office');
    await reloaded.update(reloaded.profiles.single.copyWith(favorite: true));
    expect(reloaded.profiles.single.favorite, true);
  });
  test(
    'corrupted profile store is preserved and cannot be overwritten',
    () async {
      SharedPreferences.setMockInitialValues({'profiles.v1': '{broken-data'});
      final prefs = await SharedPreferences.getInstance();
      final store = ProfileStore(prefs);
      await store.load();
      expect(store.loadError, isNotNull);
      await expectLater(
        store.save(const ConnectionProfile(id: '1', name: 'x', host: 'host')),
        throwsStateError,
      );
      expect(prefs.getString('profiles.v1'), '{broken-data');
    },
  );
  test('malformed remote dimensions do not reach the native allocator', () {
    final p = const ConnectionProfile(
      id: '1',
      name: 'x',
      host: 'host',
    ).toJson();
    p['width'] = 100000000;
    expect(
      () => ConnectionProfile.fromJson(jsonDecode(jsonEncode(p))),
      throwsFormatException,
    );
  });
  test(
    'secrets stay in the vault and certificate pins bind to an endpoint',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final vault = MemoryVault();
      final store = ProfileStore(prefs, vault: vault);
      const p = ConnectionProfile(
        id: 'secure',
        name: 'Office',
        host: 'host',
        rememberPassword: true,
      );
      await store.save(p, password: 'vault-only');
      expect(await store.password(p), 'vault-only');
      expect(prefs.getString('profiles.v1'), isNot(contains('vault-only')));
      await store.trust(p, 'sha256-fingerprint');
      expect(await store.fingerprint(p), 'sha256-fingerprint');
      expect(await store.fingerprint(p.copyWith(host: 'other-host')), '');
      await store.remove(p);
      expect(vault.values, isEmpty);
      await expectLater(store.trust(p, 'stale-pin'), throwsStateError);
      expect(vault.values, isEmpty);
    },
  );
  test('a locked vault never falls back to plaintext persistence', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final vault = MemoryVault()..locked = true;
    final store = ProfileStore(prefs, vault: vault);
    await expectLater(
      store.save(
        const ConnectionProfile(
          id: 'secure',
          name: 'Office',
          host: 'host',
          rememberPassword: true,
        ),
        password: 'vault-only',
      ),
      throwsStateError,
    );
    expect(store.profiles, isEmpty);
    expect(prefs.getString('profiles.v1'), isNull);
  });
  test(
    'concurrent profile saves are serialized without losing a connection',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProfileStore(await SharedPreferences.getInstance());
      await Future.wait(
        List.generate(
          10,
          (i) => store.save(
            ConnectionProfile(
              id: '$i',
              name: 'Work $i',
              host: '192.0.2.${i + 1}',
            ),
          ),
        ),
      );
      expect(store.profiles.length, 10);
    },
  );
}
