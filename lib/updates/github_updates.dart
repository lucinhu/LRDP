import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import '../app_version.dart';

enum UpdateFailure {
  network,
  unavailable,
  authentication,
  rateLimited,
  invalidData,
}

class UpdateException implements Exception {
  const UpdateException(this.reason);
  final UpdateFailure reason;
  @override
  String toString() => 'UpdateException(${reason.name})';
}

enum UpdateTarget {
  androidArm64,
  androidX64,
  linuxX64,
  linuxArm64,
  windowsX64,
  windowsArm64,
  macosX64,
  macosArm64,
  unsupported;

  static UpdateTarget get current => switch (Abi.current()) {
    Abi.androidArm64 => androidArm64,
    Abi.androidX64 => androidX64,
    Abi.linuxX64 => linuxX64,
    Abi.linuxArm64 => linuxArm64,
    Abi.windowsX64 => windowsX64,
    Abi.windowsArm64 => windowsArm64,
    Abi.macosX64 => macosX64,
    Abi.macosArm64 => macosArm64,
    _ => unsupported,
  };
}

class ReleaseAsset {
  const ReleaseAsset(this.name, this.url);
  final String name;
  final Uri url;
}

class GithubRelease {
  const GithubRelease({
    required this.tag,
    required this.version,
    required this.url,
    required this.notes,
    required this.prerelease,
    required this.assets,
  });
  final String tag;
  final Version version;
  final Uri url;
  final String notes;
  final bool prerelease;
  final List<ReleaseAsset> assets;

  ReleaseAsset? assetFor(UpdateTarget target) {
    final (platform, architecture, extension) = switch (target) {
      UpdateTarget.androidArm64 => ('android', 'arm64', 'apk'),
      UpdateTarget.androidX64 => ('android', 'x86_64', 'apk'),
      UpdateTarget.linuxX64 => ('linux', 'x64', 'appimage'),
      UpdateTarget.linuxArm64 => ('linux', 'arm64', 'appimage'),
      UpdateTarget.windowsX64 => ('windows', 'x64', '(?:exe|msi|zip)'),
      UpdateTarget.windowsArm64 => ('windows', 'arm64', '(?:exe|msi|zip)'),
      UpdateTarget.macosX64 => ('macos', 'x64', '(?:dmg|zip)'),
      UpdateTarget.macosArm64 => ('macos', 'arm64', '(?:dmg|zip)'),
      UpdateTarget.unsupported => ('', '', ''),
    };
    if (platform.isEmpty) return null;
    final pattern = RegExp(
      '^lrdp-[0-9][a-z0-9.+-]*-$platform-$architecture'
      '(?:-release(?:-preview)?)?\\.$extension\$',
      caseSensitive: false,
    );
    for (final asset in assets) {
      if (pattern.hasMatch(asset.name)) return asset;
    }
    return null;
  }
}

class UpdateCheck {
  const UpdateCheck(this.current, this.latest);
  final Version current;
  final GithubRelease? latest;
  bool get hasUpdate => latest != null && latest!.version > current;
}

/// Only GitHub's fixed API receives a token. Redirects and server-supplied
/// pagination URLs are deliberately not followed with Authorization attached.
class GithubUpdates {
  GithubUpdates({
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 20),
  }) : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  final Duration timeout;
  static final releasesPage = Uri.https('github.com', '/lucinhu/LRDP/releases');
  static const _maxBytes = 2 * 1024 * 1024;

  Future<UpdateCheck> check({
    required bool includePrereleases,
    String? token,
    String currentTag = appReleaseTag,
  }) async {
    final client = _clientFactory();
    try {
      return await _check(
        client,
        includePrereleases,
        token,
        currentTag,
      ).timeout(timeout);
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw const UpdateException(UpdateFailure.network);
    } catch (_) {
      throw const UpdateException(UpdateFailure.network);
    } finally {
      client.close();
    }
  }

  Future<UpdateCheck> _check(
    http.Client client,
    bool previews,
    String? token,
    String currentTag,
  ) async {
    final current = _version(currentTag);
    if (current == null) throw const UpdateException(UpdateFailure.invalidData);
    if (token != null && !RegExp(r'^[\x21-\x7e]{1,1024}$').hasMatch(token)) {
      throw const UpdateException(UpdateFailure.authentication);
    }
    GithubRelease? latest;
    for (var page = 1; page <= 5; page++) {
      final request =
          http.Request(
              'GET',
              Uri.https('api.github.com', '/repos/lucinhu/LRDP/releases', {
                'per_page': '100',
                'page': '$page',
              }),
            )
            ..followRedirects = false
            ..headers.addAll({
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'LRDP/$appReleaseTag',
              if (token != null) 'Authorization': 'Bearer $token',
            });
      final response = await client.send(request);
      switch (response.statusCode) {
        case 200:
          break;
        case 401:
          throw const UpdateException(UpdateFailure.authentication);
        case 403:
          throw UpdateException(
            response.headers['x-ratelimit-remaining'] == '0' ||
                    response.headers.containsKey('retry-after')
                ? UpdateFailure.rateLimited
                : UpdateFailure.authentication,
          );
        case 404:
          throw const UpdateException(UpdateFailure.unavailable);
        case 429:
          throw const UpdateException(UpdateFailure.rateLimited);
        default:
          throw const UpdateException(UpdateFailure.network);
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > _maxBytes) {
          throw const UpdateException(UpdateFailure.invalidData);
        }
        bytes.addAll(chunk);
      }
      final dynamic data;
      try {
        data = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        throw const UpdateException(UpdateFailure.invalidData);
      }
      if (data is! List) throw const UpdateException(UpdateFailure.invalidData);
      for (final item in data) {
        if (item is! Map<String, dynamic> || item['draft'] != false) continue;
        final tag = item['tag_name'];
        final version = tag is String ? _version(tag) : null;
        if (version == null || item['prerelease'] is! bool) continue;
        final prerelease = item['prerelease'] == true || version.isPreRelease;
        if (!previews && prerelease) continue;
        final rawUrl = item['html_url'];
        final url = rawUrl is String ? Uri.tryParse(rawUrl) : null;
        if (!_githubUrl(url) ||
            url!.pathSegments.join('/') != 'lucinhu/LRDP/releases/tag/$tag') {
          throw const UpdateException(UpdateFailure.invalidData);
        }
        final assets = <ReleaseAsset>[];
        final rawAssets = item['assets'];
        if (rawAssets is List) {
          for (final asset in rawAssets) {
            if (asset is! Map || asset['state'] != 'uploaded') continue;
            final name = asset['name'];
            final raw = asset['browser_download_url'];
            final uri = raw is String ? Uri.tryParse(raw) : null;
            if (name is String &&
                _githubUrl(uri) &&
                uri!.pathSegments.length == 6 &&
                uri.pathSegments.take(5).join('/') ==
                    'lucinhu/LRDP/releases/download/$tag' &&
                uri.pathSegments.last == name) {
              assets.add(ReleaseAsset(name, uri));
            }
          }
        }
        final notes = item['body'] is String ? item['body'] as String : '';
        final release = GithubRelease(
          tag: tag as String,
          version: version,
          url: url,
          notes: notes.length > 20000 ? notes.substring(0, 20000) : notes,
          prerelease: prerelease,
          assets: List.unmodifiable(assets),
        );
        if (latest == null || release.version > latest.version) {
          latest = release;
        }
      }
      if (data.length < 100) return UpdateCheck(current, latest);
    }
    // An incomplete listing must never produce a false "up to date" result.
    throw const UpdateException(UpdateFailure.invalidData);
  }

  static bool _githubUrl(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      !uri.hasQuery &&
      !uri.hasFragment;

  static Version? _version(String tag) {
    try {
      final parsed = Version.parse(
        tag.startsWith('v') ? tag.substring(1) : tag,
      );
      // Release build metadata is not an update channel or precedence signal.
      return Version(
        parsed.major,
        parsed.minor,
        parsed.patch,
        pre: parsed.preRelease.isEmpty ? null : parsed.preRelease.join('.'),
      );
    } on FormatException {
      return null;
    }
  }
}
