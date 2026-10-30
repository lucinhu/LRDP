import 'dart:convert';

import '../models/connection_profile.dart';

/// Marker written into every configuration backup so a foreign JSON document
/// can never be mistaken for one of ours.
const backupFormat = 'lrdp.profiles';

/// Envelope version. Bump only together with a migration path in
/// [decodeBackup]; unknown versions are rejected instead of guessed at.
const backupVersion = 1;

/// Suggested file name for the platform save dialog.
const backupSuggestedFileName = 'lrdp-profiles.json';

/// Serializes [profiles] as a deterministic JSON envelope.
///
/// Only [ConnectionProfile.toJson] data is written, so the document never
/// contains passwords or trusted certificate fingerprints: those live in the
/// platform vault keyed by profile id and are not part of the model JSON.
String encodeBackup(List<ConnectionProfile> profiles) => jsonEncode({
  'format': backupFormat,
  'version': backupVersion,
  'profiles': [for (final profile in profiles) profile.toJson()],
});

/// Why [decodeBackup] refused a document.
enum BackupError { invalidJson, invalidFormat, unsupportedVersion, empty }

/// Outcome of [decodeBackup]: either [profiles] is a non-empty, duplicate-free
/// list and [error] is null, or [profiles] is empty and [error] explains why.
class BackupParseResult {
  const BackupParseResult._(this.profiles, this.error);
  const BackupParseResult.success(List<ConnectionProfile> profiles)
    : this._(profiles, null);
  const BackupParseResult.failure(BackupError error) : this._(const [], error);

  final List<ConnectionProfile> profiles;
  final BackupError? error;

  bool get isSuccess => error == null;
}

/// Parses and validates a backup document without touching the filesystem.
///
/// The envelope must carry [backupFormat], [backupVersion] and a non-empty
/// `profiles` array whose entries all satisfy [ConnectionProfile.fromJson].
/// A document that lists the same endpoint + username twice is rejected as
/// malformed: resolving that ambiguity is left to [mergeBackup] against the
/// profiles already on this device, not to guessing inside one file.
BackupParseResult decodeBackup(String text) {
  Object? raw;
  try {
    // Editors on Windows may add a BOM; JSON itself never starts with one.
    raw = jsonDecode(text.startsWith('\ufeff') ? text.substring(1) : text);
  } catch (_) {
    return const BackupParseResult.failure(BackupError.invalidJson);
  }
  if (raw is! Map<String, dynamic>) {
    return const BackupParseResult.failure(BackupError.invalidFormat);
  }
  if (raw['format'] != backupFormat) {
    return const BackupParseResult.failure(BackupError.invalidFormat);
  }
  final version = raw['version'];
  if (version is! int) {
    return const BackupParseResult.failure(BackupError.invalidFormat);
  }
  if (version != backupVersion) {
    return const BackupParseResult.failure(BackupError.unsupportedVersion);
  }
  final entries = raw['profiles'];
  if (entries is! List) {
    return const BackupParseResult.failure(BackupError.invalidFormat);
  }
  if (entries.isEmpty) {
    return const BackupParseResult.failure(BackupError.empty);
  }
  final profiles = <ConnectionProfile>[];
  final identities = <String>{};
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) {
      return const BackupParseResult.failure(BackupError.invalidFormat);
    }
    final ConnectionProfile profile;
    try {
      profile = ConnectionProfile.fromJson(entry);
    } catch (_) {
      return const BackupParseResult.failure(BackupError.invalidFormat);
    }
    if (!identities.add(_identity(profile))) {
      return const BackupParseResult.failure(BackupError.invalidFormat);
    }
    profiles.add(profile);
  }
  return BackupParseResult.success(profiles);
}

/// Decides which [incoming] profiles to save next to [existing] ones.
///
/// A profile is skipped when an existing profile already uses the same
/// host + port + username (host and username compared case-insensitively),
/// or when an earlier incoming profile in the same file does. Skipped entries
/// are counted, accepted entries keep their [incoming] order, and an accepted
/// profile whose id is already in use is cloned with a fresh, unique id such
/// as `meeting-import-2`. The returned [profiles] are exactly the ones the
/// caller has to persist.
({List<ConnectionProfile> profiles, int imported, int skipped}) mergeBackup({
  required List<ConnectionProfile> existing,
  required List<ConnectionProfile> incoming,
}) {
  final usedIds = {for (final profile in existing) profile.id};
  final identities = {for (final profile in existing) _identity(profile)};
  final profiles = <ConnectionProfile>[];
  var skipped = 0;
  for (final profile in incoming) {
    if (!identities.add(_identity(profile))) {
      skipped++;
      continue;
    }
    var id = profile.id;
    if (usedIds.contains(id)) {
      var suffix = 1;
      while (usedIds.contains('${profile.id}-import-$suffix')) {
        suffix++;
      }
      id = '${profile.id}-import-$suffix';
    }
    usedIds.add(id);
    profiles.add(id == profile.id ? profile : _withId(profile, id));
  }
  return (profiles: profiles, imported: profiles.length, skipped: skipped);
}

/// Endpoint + account identity used for duplicate detection. Passwords and
/// certificate pins are deliberately not part of it.
String _identity(ConnectionProfile profile) =>
    '${profile.host.toLowerCase()}\u0000${profile.port}\u0000'
    '${profile.username.toLowerCase()}';

/// [ConnectionProfile.copyWith] intentionally does not expose `id`, so clone
/// through the stable JSON shape, which already carries every stored field.
ConnectionProfile _withId(ConnectionProfile profile, String id) =>
    ConnectionProfile.fromJson({...profile.toJson(), 'id': id});
