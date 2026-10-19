import 'dart:async';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';

/// Existing interaction tests deliberately exercise the Simplified Chinese UI,
/// independent of the build host. Localization tests override this explicitly.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .localesTestValue = [
    const Locale('zh', 'CN'),
  ];
  await testMain();
}
