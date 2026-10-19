import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'messages.dart';

/// Source-language message IDs keep translations independent of profile data.
/// Positional placeholders are substituted once, after lookup; user text is
/// never treated as another message or interpreted as formatting instructions.
class AppStrings {
  const AppStrings(this.locale, this.messages);
  final Locale locale;
  final Map<String, String> messages;
  static const fallback = AppStrings(Locale('zh', 'CN'), {});
  static const supportedLocales = [
    Locale('zh', 'CN'),
    Locale('zh', 'TW'),
    Locale('en'),
  ];
  static const languageNames = {
    'system': '跟随系统',
    'zh-CN': '简体中文',
    'zh-TW': '繁體中文',
    'en': 'English',
  };
  static const delegate = _AppStringsDelegate();
  static Locale? localeFor(String value) => switch (value) {
    'zh-CN' => const Locale('zh', 'CN'),
    'zh-TW' => const Locale('zh', 'TW'),
    'en' => const Locale('en'),
    _ => null,
  };
  static Locale resolve(List<Locale>? preferred, Iterable<Locale> supported) {
    for (final locale in preferred ?? const <Locale>[]) {
      if (locale.languageCode == 'zh') {
        return locale.scriptCode == 'Hant' ||
                {'TW', 'HK', 'MO'}.contains(locale.countryCode)
            ? supportedLocales[1]
            : supportedLocales[0];
      }
      if (locale.languageCode == 'en') return supportedLocales[2];
    }
    return supportedLocales[2];
  }

  String text(String source, [List<Object?> values = const []]) =>
      (messages[source] ?? source).replaceAllMapped(RegExp(r'\{(\d+)\}'), (m) {
        final index = int.parse(m[1]!);
        return index < values.length ? '${values[index]}' : m[0]!;
      });
}

class _AppStringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppStringsDelegate();
  @override
  bool isSupported(Locale locale) => {'zh', 'en'}.contains(locale.languageCode);
  @override
  Future<AppStrings> load(Locale locale) {
    final name = locale.languageCode == 'en'
        ? 'en'
        : locale.countryCode == 'TW'
        ? 'zh-TW'
        : 'zh-CN';
    return SynchronousFuture(AppStrings(locale, localizedMessages[name]!));
  }

  @override
  bool shouldReload(_AppStringsDelegate old) => false;
}

extension TranslatedContext on BuildContext {
  String tr(String source, [List<Object?> values = const []]) =>
      (Localizations.of<AppStrings>(this, AppStrings) ?? AppStrings.fallback)
          .text(source, values);
}
