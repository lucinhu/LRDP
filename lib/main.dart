import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'app.dart';
import 'data/profile_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final component in [
      'FreeRDP',
      'OpenSSL',
      'AndroidCpuFeatures',
      'FFmpeg',
    ]) {
      yield LicenseEntryWithLineBreaks([
        component,
      ], await rootBundle.loadString('assets/licenses/$component.txt'));
    }
  });
  final store = ProfileStore(await SharedPreferences.getInstance());
  await store.load();
  final applicationDirectory = await getApplicationSupportDirectory();
  runApp(
    LrdpApp(
      store: store,
      protocolDirectory: '${applicationDirectory.path}/freerdp',
    ),
  );
}
