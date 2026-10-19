import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'data/profile_store.dart';
import 'ui/theme.dart';
import 'ui/workspace_screen.dart';

class LrdpApp extends StatelessWidget {
  const LrdpApp({super.key, required this.store, this.protocolDirectory});
  final ProfileStore store;
  final String? protocolDirectory;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (_, _) => MaterialApp(
      title: 'LRDP',
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: store.darkMode ? ThemeMode.dark : ThemeMode.light,
      home: WorkspaceScreen(store: store, protocolDirectory: protocolDirectory),
    ),
  );
}
