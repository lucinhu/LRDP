import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lrdp/app.dart';
import 'package:lrdp/data/profile_store.dart';
import 'package:lrdp/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<ProfileStore> store([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return ProfileStore(await SharedPreferences.getInstance());
  }

  tearDown(
    () => messenger.setMockMethodCallHandler(DynamicColorPlugin.channel, null),
  );

  test(
    'appearance defaults, legacy selections and new preferences survive reload',
    () async {
      expect((await store()).themeMode, ThemeMode.system);
      expect((await store({'darkMode': true})).themeMode, ThemeMode.dark);
      expect((await store({'darkMode': false})).themeMode, ThemeMode.light);
      final profiles = await store({'darkMode': true, 'frameRateLimit': 999});
      expect(profiles.frameRateLimit, 0);
      await profiles.setThemeMode(ThemeMode.system);
      await profiles.setSystemColors(false);
      await profiles.setFrameRateLimit(144);
      final reloaded = ProfileStore(await SharedPreferences.getInstance());
      expect(reloaded.themeMode, ThemeMode.system);
      expect(reloaded.useSystemColors, false);
      expect(reloaded.frameRateLimit, 144);
      await expectLater(reloaded.setFrameRateLimit(999), throwsArgumentError);
      expect(reloaded.frameRateLimit, 144);
    },
  );

  testWidgets(
    'system brightness changes keep an open connection draft; manual mode overrides',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dispatcher = tester.platformDispatcher;
      addTearDown(dispatcher.clearPlatformBrightnessTestValue);
      dispatcher.platformBrightnessTestValue = Brightness.light;
      final profiles = await store();
      await tester.pumpWidget(LrdpApp(store: profiles));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加电脑').first);
      await tester.pumpAndSettle();
      final address = find.byKey(const Key('profileAddress'));
      await tester.enterText(address, '192.0.2.80');
      dispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(address)).brightness, Brightness.dark);
      expect(
        tester
            .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
              find.byKey(const Key('systemUiStyle')),
            )
            .value
            .statusBarIconBrightness,
        Brightness.light,
      );
      expect(
        tester.widget<TextFormField>(address).controller!.text,
        '192.0.2.80',
      );
      await profiles.setThemeMode(ThemeMode.light);
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(address)).brightness, Brightness.light);
      expect(
        tester
            .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
              find.byKey(const Key('systemUiStyle')),
            )
            .value
            .statusBarIconBrightness,
        Brightness.dark,
      );
      expect(
        tester.widget<TextFormField>(address).controller!.text,
        '192.0.2.80',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'system accent refreshes on foreground and falls back when unavailable',
    (tester) async {
      var accent = Colors.purple.toARGB32();
      int? available = accent;
      messenger.setMockMethodCallHandler(DynamicColorPlugin.channel, (
        call,
      ) async {
        return call.method == 'getAccentColor' ? available : null;
      });
      final profiles = await store();
      await tester.pumpWidget(LrdpApp(store: profiles));
      await tester.pumpAndSettle();
      Color primary() => Theme.of(
        tester.element(find.byType(Scaffold).first),
      ).colorScheme.primary;
      expect(primary(), ColorScheme.fromSeed(seedColor: Color(accent)).primary);
      accent = Colors.orange.toARGB32();
      available = accent;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(primary(), ColorScheme.fromSeed(seedColor: Color(accent)).primary);
      available = null;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(primary(), appTheme(Brightness.light).colorScheme.primary);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
