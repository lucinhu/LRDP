import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lrdp/ui/session_fullscreen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('late platform enter completes before the requested exit', () async {
    const channel = MethodChannel('dev.lrdp/window');
    final requests = <bool>[];
    final gate = Completer<void>();
    final entered = Completer<void>(), exited = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'fullscreen');
      requests.add(call.arguments as bool);
      if (call.arguments == true) {
        entered.complete();
        await gate.future;
      } else {
        exited.complete();
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final fullscreen = SessionFullscreen();
    fullscreen.set(true, TargetPlatform.linux);
    fullscreen.set(false, TargetPlatform.linux);
    await entered.future.timeout(const Duration(seconds: 2));
    expect(requests, [true]);
    gate.complete();
    await exited.future.timeout(const Duration(seconds: 2));
    expect(requests, [true, false]);
    fullscreen.set(false, TargetPlatform.linux);
    await Future<void>.delayed(Duration.zero);
    expect(requests, [true, false]);
  });

  test('platform rejection does not prevent a later restore', () async {
    const channel = MethodChannel('dev.lrdp/window');
    final requests = <bool>[];
    final exited = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      requests.add(call.arguments as bool);
      if (call.arguments == true) throw PlatformException(code: 'denied');
      exited.complete();
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final fullscreen = SessionFullscreen();
    fullscreen.set(true, TargetPlatform.windows);
    fullscreen.set(false, TargetPlatform.windows);
    await exited.future.timeout(const Duration(seconds: 2));
    expect(requests, [true, false]);
  });
}
