import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/connection_profile.dart';

class ProfileStore extends ChangeNotifier {
  ProfileStore(this._preferences, {FlutterSecureStorage? vault})
    : _vault = vault ?? const FlutterSecureStorage();
  final SharedPreferences _preferences;
  final FlutterSecureStorage _vault;
  List<ConnectionProfile> _profiles = [];
  List<ConnectionProfile> get profiles => List.unmodifiable(_profiles);
  String? loadError;
  Future<void> _pending = Future.value();
  Future<void> _serialize(Future<void> Function() action) {
    final operation = _pending.then((_) => action());
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  ThemeMode get themeMode {
    final saved = _preferences.getString('themeMode');
    for (final mode in ThemeMode.values) {
      if (mode.name == saved) return mode;
    }
    // Keep an explicitly selected appearance from older installations.
    final legacy = _preferences.getBool('darkMode');
    return legacy == null
        ? ThemeMode.system
        : legacy
        ? ThemeMode.dark
        : ThemeMode.light;
  }

  bool get useSystemColors => _preferences.getBool('systemColors') ?? true;
  static const languages = ['system', 'zh-CN', 'zh-TW', 'en'];
  String get language {
    final saved = _preferences.getString('language');
    return languages.contains(saved) ? saved! : 'system';
  }

  Future<void> setLanguage(String value) => _serialize(() async {
    if (!languages.contains(value)) {
      throw ArgumentError.value(value, 'language');
    }
    if (!await _preferences.setString('language', value)) {
      throw StateError('无法保存语言设置');
    }
    notifyListeners();
  });
  bool get openFullscreen => _preferences.getBool('openFullscreen') ?? true;
  Future<void> setOpenFullscreen(bool value) => _serialize(() async {
    if (!await _preferences.setBool('openFullscreen', value)) {
      throw StateError('无法保存全屏设置');
    }
    notifyListeners();
  });
  static const frameRateOptions = [0, 30, 60, 90, 120, 144, 165, 240];
  int get frameRateLimit {
    final value = _preferences.getInt('frameRateLimit') ?? 0;
    return frameRateOptions.contains(value) ? value : 0;
  }

  Future<void> load() async {
    final raw = _preferences.getString('profiles.v1');
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      _profiles = decoded
          .map((j) => ConnectionProfile.fromJson(j as Map<String, dynamic>))
          .toList();
      if (_profiles.map((p) => p.id).toSet().length != _profiles.length) {
        throw const FormatException('连接 ID 重复');
      }
    } catch (_) {
      _profiles = [];
      loadError = '连接配置无法读取，原始数据已保留且不会覆盖。请从应用配置目录恢复备份。';
    }
    notifyListeners();
  }

  Future<void> _save(List<ConnectionProfile> next) async {
    if (loadError != null) throw StateError(loadError!);
    if (!await _preferences.setString(
      'profiles.v1',
      jsonEncode(next.map((p) => p.toJson()).toList()),
    )) {
      throw StateError('无法保存连接，请检查存储空间');
    }
    _profiles = next;
    notifyListeners();
  }

  Future<void> save(
    ConnectionProfile p, {
    String? password,
  }) => _serialize(() async {
    // Complete secure storage before publishing a profile that promises a saved secret.
    if (password != null && p.rememberPassword) {
      await _vault.write(key: 'password.${p.id}', value: password);
    } else if (!p.rememberPassword &&
        _profiles.any((v) => v.id == p.id && v.rememberPassword)) {
      await _vault.delete(key: 'password.${p.id}');
    }
    final next = [..._profiles];
    final i = next.indexWhere((v) => v.id == p.id);
    if (i < 0) {
      next.add(p);
    } else {
      next[i] = p;
    }
    await _save(next);
  });

  Future<void> update(ConnectionProfile p) => _serialize(() async {
    final next = [..._profiles];
    final i = next.indexWhere((v) => v.id == p.id);
    if (i >= 0) {
      next[i] = p;
      await _save(next);
    }
  });

  Future<void> remove(ConnectionProfile p) => _serialize(() async {
    await _vault.delete(key: 'password.${p.id}');
    await _vault.delete(key: 'certificate.${p.id}');
    await _save(_profiles.where((v) => v.id != p.id).toList());
  });

  Future<String> password(ConnectionProfile p) async => p.rememberPassword
      ? await _vault.read(key: 'password.${p.id}') ?? ''
      : '';
  Future<String> fingerprint(ConnectionProfile p) async {
    final value = await _vault.read(key: 'certificate.${p.id}');
    if (value == null) return '';
    final stored = jsonDecode(value) as Map<String, dynamic>;
    return stored['address'] == p.address ? stored['sha256'] as String : '';
  }

  Future<void> trust(ConnectionProfile p, String fingerprint) =>
      _serialize(() async {
        if (!_profiles.any((v) => v.id == p.id && v.address == p.address)) {
          throw StateError('连接已移除或地址已变化');
        }
        await _vault.write(
          key: 'certificate.${p.id}',
          value: jsonEncode({'address': p.address, 'sha256': fingerprint}),
        );
      });
  Future<void> forgetCertificate(ConnectionProfile p) =>
      _vault.delete(key: 'certificate.${p.id}');
  Future<void> setThemeMode(ThemeMode value) => _serialize(() async {
    if (!await _preferences.setString('themeMode', value.name)) {
      throw StateError('无法保存外观设置');
    }
    notifyListeners();
  });

  Future<void> setSystemColors(bool value) => _serialize(() async {
    if (!await _preferences.setBool('systemColors', value)) {
      throw StateError('无法保存配色设置');
    }
    notifyListeners();
  });

  Future<void> setFrameRateLimit(int value) => _serialize(() async {
    if (!frameRateOptions.contains(value)) throw ArgumentError.value(value);
    if (!await _preferences.setInt('frameRateLimit', value)) {
      throw StateError('无法保存帧率设置');
    }
    notifyListeners();
  });
}
