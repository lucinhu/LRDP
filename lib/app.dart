import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'data/profile_store.dart';
import 'ui/theme.dart';
import 'ui/system_colors.dart';
import 'ui/workspace_screen.dart';

class LrdpApp extends StatelessWidget {
  const LrdpApp({super.key, required this.store, this.protocolDirectory});
  final ProfileStore store;
  final String? protocolDirectory;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (_, _) => SystemColors(
      enabled: store.useSystemColors,
      builder: (light, dark) => MaterialApp(
        title: 'LRDP',
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light, systemColors: light),
        darkTheme: appTheme(Brightness.dark, systemColors: dark),
        themeMode: store.themeMode,
        builder: (context, child) {
          final scheme = Theme.of(context).colorScheme;
          final dark = scheme.brightness == Brightness.dark;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            key: const Key('systemUiStyle'),
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarBrightness: scheme.brightness,
              statusBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
              systemNavigationBarColor: scheme.surface,
              systemNavigationBarIconBrightness: dark
                  ? Brightness.light
                  : Brightness.dark,
            ),
            child: child ?? const SizedBox(),
          );
        },
        home: WorkspaceScreen(
          store: store,
          protocolDirectory: protocolDirectory,
        ),
      ),
    ),
  );
}
