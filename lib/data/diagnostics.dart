import 'dart:io';

import '../app_version.dart';
import '../l10n/app_strings.dart';
import 'profile_store.dart';

/// Builds the sanitized support report from already-sanitized inputs.
///
/// [settings] must contain display and app preferences only. Connection
/// profiles are deliberately absent from this API, so hosts, user names,
/// domains, passwords, certificate fingerprints and tokens cannot leak into
/// the report. Setting keys are sorted and every value is folded onto a single
/// line, so the text stays stable for tests and for pasting into a message.
String buildDiagnostics({
  required String appTag,
  required String platform,
  required String locale,
  required int profileCount,
  required Map<String, Object?> settings,
  Iterable<int> decoderBackends = const [],
}) {
  final backends = decoderBackends.toList();
  final keys = settings.keys.toList()..sort();
  final lines = <String>[
    'LRDP 诊断信息',
    '版本: ${_singleLine(appTag)}',
    '平台: ${_singleLine(platform)}',
    '语言: ${_singleLine(locale)}',
    '连接配置: $profileCount',
    '设置:',
    for (final key in keys)
      '  ${_singleLine(key)}: ${_singleLine('${settings[key]}')}',
    if (backends.isNotEmpty) ...[
      'H.264 解码（各会话最近成功帧，0=未知，1=CPU/FFmpeg，2=GPU/VA-API，3=GPU/CUDA，4=硬件/MediaCodec）:',
      for (var i = 0; i < backends.length; i++)
        '  session[${i + 1}].decoderBackend: ${backends[i]}',
    ],
  ];
  return lines.join('\n');
}

/// Collects the support report for the current installation.
///
/// Reads the release tag, host platform, language preference, profile count
/// and display/update preferences, with anonymous decoder backend values.
/// Profile contents, secure-storage values and update tokens are never read.
Future<String> collectDiagnostics(
  ProfileStore store, {
  Iterable<int> decoderBackends = const [],
}) async {
  final language = store.language;
  return buildDiagnostics(
    appTag: appReleaseTag,
    platform: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    locale: AppStrings.languageNames[language] ?? language,
    profileCount: store.profiles.length,
    decoderBackends: decoderBackends,
    settings: <String, Object?>{
      'themeMode': store.themeMode.name,
      'frameRateLimit': store.frameRateLimit,
      'imageScaling': store.imageScaling.name,
      'pointerSpeed': store.pointerSpeed,
      'openFullscreen': store.resolveOpenFullscreen(
        mobile: Platform.isAndroid || Platform.isIOS,
      ),
      'useSystemColors': store.useSystemColors,
      'includePreviewUpdates': store.includePreviewUpdates,
    },
  );
}

final _lineBreak = RegExp(r'[\x00-\x1F\x7F]+');
final _repeatedSpaces = RegExp(r' {2,}');

/// Keeps one report field per line, even if a caller passes odd text.
String _singleLine(String value) =>
    value.replaceAll(_lineBreak, ' ').replaceAll(_repeatedSpaces, ' ').trim();
