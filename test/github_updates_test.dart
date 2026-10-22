import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lrdp/updates/github_updates.dart';

Map<String, dynamic> release(
  String tag, {
  bool preview = false,
  bool draft = false,
  List<Map<String, dynamic>> assets = const [],
}) => {
  'tag_name': tag,
  'prerelease': preview,
  'draft': draft,
  'html_url': 'https://github.com/lucinhu/LRDP/releases/tag/$tag',
  'body': 'Release notes',
  'assets': assets,
};
Map<String, dynamic> asset(String tag, String name) => {
  'name': name,
  'state': 'uploaded',
  'browser_download_url':
      'https://github.com/lucinhu/LRDP/releases/download/$tag/$name',
};
GithubUpdates feed(List<Map<String, dynamic>> releases) => GithubUpdates(
  clientFactory: () =>
      MockClient((_) async => http.Response(jsonEncode(releases), 200)),
);
Matcher failure(UpdateFailure reason) =>
    isA<UpdateException>().having((e) => e.reason, 'reason', reason);

void main() {
  test(
    'numeric preview ordering, build metadata and stable precedence',
    () async {
      final service = feed([
        release('v0.1.0-preview.2', preview: true),
        release('v0.1.0-preview.10+local', preview: true),
        release('v0.1.0-preview.9', preview: true),
        release('v0.1.0-preview.99', preview: true, draft: true),
        release('release-not-a-version'),
      ]);
      final result = await service.check(
        includePrereleases: true,
        currentTag: 'v0.1.0-preview.3',
      );
      expect(result.latest!.tag, 'v0.1.0-preview.10+local');
      expect(result.hasUpdate, isTrue);
      final stable = await feed([
        release('v0.1.0'),
        release('v0.1.0-rc.99'),
      ]).check(includePrereleases: true, currentTag: 'v0.1.0-preview.10');
      expect(stable.latest!.tag, 'v0.1.0');
      expect(stable.hasUpdate, isTrue);
      final equal = await feed([
        release('v0.1.0+99'),
      ]).check(includePrereleases: false, currentTag: 'v0.1.0+1');
      expect(equal.hasUpdate, isFalse);
    },
  );
  test(
    'stable channel excludes prerelease flag and prerelease tags; no downgrade',
    () async {
      final result = await feed([
        release('v0.3.0', preview: true),
        release('v0.4.0-beta.1'),
        release('v0.2.0'),
        release('v9.0.0', draft: true),
      ]).check(includePrereleases: false, currentTag: 'v0.2.1');
      expect(result.latest!.tag, 'v0.2.0');
      expect(result.hasUpdate, isFalse);
      expect((await feed([]).check(includePrereleases: false)).latest, isNull);
    },
  );
  test(
    'requests fixed API with header-only auth and safe pagination',
    () async {
      var requests = 0;
      final service = GithubUpdates(
        clientFactory: () => MockClient((request) async {
          requests++;
          expect(request.url.host, 'api.github.com');
          expect(request.url.path, '/repos/lucinhu/LRDP/releases');
          expect(request.url.queryParameters['page'], '$requests');
          expect(request.headers['Authorization'], 'Bearer fixture_token');
          expect(request.url.toString(), isNot(contains('fixture_token')));
          expect(request.followRedirects, isFalse);
          return http.Response(
            jsonEncode(
              requests == 1
                  ? List.generate(100, (_) => release('v0.1.1'))
                  : [release('v0.2.0')],
            ),
            200,
            headers: {'link': '<https://untrusted.invalid/page>; rel="next"'},
          );
        }),
      );
      final result = await service.check(
        includePrereleases: false,
        token: 'fixture_token',
      );
      expect(requests, 2);
      expect(result.latest!.tag, 'v0.2.0');
    },
  );
  test('too many pages cannot claim up to date', () async {
    await expectLater(
      feed(
        List.generate(100, (_) => release('v0.1.0')),
      ).check(includePrereleases: false),
      throwsA(failure(UpdateFailure.invalidData)),
    );
  });
  for (final (status, headers, expected) in [
    (401, <String, String>{}, UpdateFailure.authentication),
    (403, <String, String>{}, UpdateFailure.authentication),
    (403, {'x-ratelimit-remaining': '0'}, UpdateFailure.rateLimited),
    (403, {'retry-after': '30'}, UpdateFailure.rateLimited),
    (404, <String, String>{}, UpdateFailure.unavailable),
    (429, <String, String>{}, UpdateFailure.rateLimited),
    (503, <String, String>{}, UpdateFailure.network),
    (302, {'location': 'https://untrusted.invalid'}, UpdateFailure.network),
  ]) {
    test('HTTP $status/$headers returns a safe typed failure', () async {
      final service = GithubUpdates(
        clientFactory: () => MockClient(
          (_) async => http.Response(
            'server body must never leak fixture_token',
            status,
            headers: headers,
          ),
        ),
      );
      try {
        await service.check(includePrereleases: true, token: 'fixture_token');
        fail('Expected failure');
      } on UpdateException catch (e) {
        expect(e, failure(expected));
        expect(e.toString(), isNot(contains('fixture_token')));
      }
    });
  }
  test(
    'malformed, oversized, and untrusted release responses are rejected',
    () async {
      for (final body in [
        '{not-json',
        '{}',
        'x' * (2 * 1024 * 1024 + 1),
        jsonEncode([
          release('v9.0.0')..['html_url'] = 'https://untrusted.invalid/release',
        ]),
      ]) {
        final service = GithubUpdates(
          clientFactory: () =>
              MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(
          service.check(includePrereleases: true),
          throwsA(failure(UpdateFailure.invalidData)),
        );
      }
    },
  );
  test('bad token never reaches HTTP or exception messages', () async {
    var calls = 0;
    final service = GithubUpdates(
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('[]', 200);
      }),
    );
    await expectLater(
      service.check(includePrereleases: true, token: 'fixture\r\nheader'),
      throwsA(failure(UpdateFailure.authentication)),
    );
    expect(calls, 0);
  });
  test('timeout closes the client', () async {
    final pending = Completer<http.Response>();
    final client = ClosingClient((_) => pending.future);
    final service = GithubUpdates(
      clientFactory: () => client,
      timeout: const Duration(milliseconds: 10),
    );
    await expectLater(
      service.check(includePrereleases: false),
      throwsA(failure(UpdateFailure.network)),
    );
    expect(client.closed, isTrue);
    pending.complete(http.Response('[]', 200));
  });
  test(
    'downloads match OS and architecture, rejecting foreign or incomplete assets',
    () async {
      const tag = 'v0.2.0';
      final result = await feed([
        release(
          tag,
          assets: [
            asset(tag, 'lrdp-0.2.0-android-arm64-release-preview.apk'),
            asset(tag, 'lrdp-0.2.0-linux-x64.AppImage'),
            asset(tag, 'lrdp-0.2.0-source.tar.gz'),
            asset(tag, 'lrdp-0.2.0-windows-x64.zip')
              ..['browser_download_url'] = 'https://untrusted.invalid/file.zip',
            asset(tag, 'lrdp-0.2.0-linux-arm64.AppImage')..['state'] = 'new',
          ],
        ),
      ]).check(includePrereleases: false);
      final latest = result.latest!;
      expect(
        latest.assetFor(UpdateTarget.androidArm64)!.name,
        endsWith('.apk'),
      );
      expect(
        latest.assetFor(UpdateTarget.linuxX64)!.name,
        endsWith('.AppImage'),
      );
      for (final target in [
        UpdateTarget.androidX64,
        UpdateTarget.linuxArm64,
        UpdateTarget.windowsX64,
        UpdateTarget.macosArm64,
        UpdateTarget.unsupported,
      ]) {
        expect(latest.assetFor(target), isNull);
      }
    },
  );
}

class ClosingClient extends MockClient {
  ClosingClient(super.fn);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}
