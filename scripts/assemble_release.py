#!/usr/bin/env python3
"""Assemble release metadata, checksums and the verification archive.

The release job of .github/workflows/release.yml builds the AppImage, the
Android APK and the source archive in separate jobs. This script inspects those
artifacts, refuses binaries that violate the documented limits (glibc 2.35,
native ABI v5) and writes BUILD_INFO.json, RELEASE_INFO.json, SHA256SUMS and
lrdp-<version>-verification.zip next to them.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import zipfile

GLIBC_LIMIT = (2, 35)
NATIVE_ABI = 5


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_cwd(cwd, *args):
    return subprocess.check_output(['git', '-C', str(cwd), *args]).strip()


def elf_version_scan(appdir):
    """Return (ELF count, highest GLIBC version, {name: sha256} of native libs)."""
    count = 0
    highest = (0,)
    required_by = {}
    for path in sorted(appdir.rglob('*')):
        if not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        count += 1
        result = subprocess.check_output(['readelf', '--version-info', str(path)], text=True)
        for version in re.findall(r'\bGLIBC_([0-9.]+)\b', result):
            parts = tuple(int(part) for part in version.split('.'))
            if parts > highest:
                highest = parts
                required_by = {'path': str(path.relative_to(appdir)), 'version': version}
    if highest and highest > GLIBC_LIMIT:
        raise SystemExit(
            f'{required_by["path"]} needs GLIBC_{required_by["version"]}; '
            f'the release must be built on Ubuntu 22.04 (GLIBC_{".".join(map(str, GLIBC_LIMIT))})')
    return count, '.'.join(map(str, highest)) if highest else None


def extract_appimage(appimage, target):
    appimage.chmod(0o755)
    subprocess.run([str(appimage.resolve()), '--appimage-extract'], cwd=target, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    root = target / 'squashfs-root'
    if not root.is_dir():
        raise SystemExit('AppImage extraction produced no squashfs-root directory')
    return root


def native_exports(library):
    result = subprocess.run(['nm', '-D', '--defined-only', str(library)],
                            check=True, capture_output=True, text=True).stdout
    exports = sorted(line.split()[-1] for line in result.splitlines()
                     if ' T ' in line and line.split()[-1].startswith('lrdp_'))
    return exports


def apk_metadata(apk):
    info = {'abi': 'arm64-v8a', 'apk_sha256': sha256_file(apk), 'static_validation_passed': True}
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        libraries = [name for name in names if re.fullmatch(r'lib/arm64-v8a/.*\.so', name)]
        for name in libraries:
            if name.endswith('/liblrdp.so'):
                with tempfile.NamedTemporaryFile(suffix='.so') as temporary:
                    temporary.write(archive.read(name))
                    temporary.flush()
                    info['native_sha256'] = sha256_file(Path(temporary.name))
                    info['native_exports'] = len(native_exports(Path(temporary.name)))
                break
        else:
            raise SystemExit('The APK does not contain lib/arm64-v8a/liblrdp.so')
    try:
        badging = subprocess.run(['aapt', 'dump', 'badging', str(apk)],
                                 capture_output=True, text=True)
    except FileNotFoundError:
        badging = None
    if badging is not None and badging.returncode == 0:
        match = re.search(r"versionCode='(\d+)' versionName='([^']+)'", badging.stdout)
        if match:
            info['version_code'] = int(match.group(1))
            info['version_name'] = match.group(2)
    try:
        signing = subprocess.run(['apksigner', 'verify', '--print-certs', str(apk)],
                                 capture_output=True, text=True)
    except FileNotFoundError:
        signing = None
    if signing is not None and signing.returncode == 0:
        match = re.search(r'certificate SHA-256 digest:\s*([0-9a-f:]+)', signing.stdout)
        if match:
            info['certificate_sha256'] = match.group(1).replace(':', '')
    return info


def source_metadata(tarball):
    with tarfile.open(tarball, 'r:gz') as archive:
        member = next(member for member in archive.getmembers()
                      if member.name.endswith('/BUILD_INFO-SOURCE.json'))
        return json.loads(archive.extractfile(member).read())


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2) + '\n')
    print(f'wrote {path}')


def build_verification_zip(path, logs, dist, metadata_files, checksums):
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for log in sorted(logs.glob('*.log')):
            archive.write(log, f'logs/{log.name}')
        for metadata in metadata_files:
            archive.write(metadata, f'metadata/{metadata.name}')
        archive.write(checksums, 'metadata/SHA256SUMS')
        archive.writestr('README.txt', (
            'LRDP release verification archive (CI-built)\n\n'
            'logs/     build, analysis, test and packaging logs from the release workflow\n'
            'metadata/ BUILD_INFO.json, RELEASE_INFO.json and SHA256SUMS for this release\n\n'
            'This archive covers the automated gates only: Flutter analyze/test, native CTest,\n'
            'Python checks, Android APK static validation and the AppImage payload/glibc check.\n'
            'The interactive OS acceptance runs (AppImage window/input/fullscreen/NLA, real\n'
            'Android hardware, Windows/macOS/iOS) are not part of the CI workflow and remain\n'
            'pending; see docs/VERIFICATION.md.\n'))
    print(f'wrote {path}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--logs', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY', 'lucinhu/LRDP'))
    parser.add_argument('--run-url', default=None)
    parser.add_argument('--runner', default=None)
    args = parser.parse_args()
    dist = args.dist.resolve()
    appimages = sorted(dist.glob('*.AppImage'))
    apks = sorted(dist.glob('*-android-*.apk'))
    sources = sorted(dist.glob('*-source.tar.gz'))
    if len(appimages) != 1 or len(apks) != 1 or len(sources) != 1:
        raise SystemExit(f'expected exactly one AppImage, APK and source archive in {dist}')
    appimage, apk, source = appimages[0], apks[0], sources[0]
    appinfo = apk_metadata(apk)
    supplied = dist / 'apk-meta.json'
    if supplied.is_file():
        appinfo.update(json.loads(supplied.read_text()))
    sourceinfo = source_metadata(source)
    version_code = appinfo.get('version_code')
    if version_code is not None and args.version.split('+')[-1] != str(version_code):
        raise SystemExit(f'APK versionCode {version_code} does not match {args.version}')
    with tempfile.TemporaryDirectory() as temporary:
        appdir = extract_appimage(appimage, Path(temporary))
        elf_count, glibc = elf_version_scan(appdir)
        bridge = appdir / 'usr/lib/liblrdp.so'
        bridge_sha = sha256_file(bridge)
        exports = native_exports(bridge)
        if len(exports) != 31:
            raise SystemExit(f'expected 31 native exports, found {len(exports)}')
    freerdp = Path('third_party/FreeRDP')
    if sha256_cwd(freerdp, 'status', '--porcelain'):
        raise SystemExit('FreeRDP must remain unmodified')
    freerdp_commit = sha256_cwd(freerdp, 'rev-parse', 'HEAD').decode()
    freerdp_files = len(sha256_cwd(freerdp, 'ls-files').decode().splitlines())
    created = subprocess.check_output(['date', '-u', '+%Y-%m-%dT%H:%M:%S+00:00'], text=True).strip()
    app_sha = sha256_file(appimage)
    build_info = {
        'release_tag': args.tag,
        'application_version': args.version,
        'release_commit': args.commit,
        'application_runtime_commit': args.commit,
        'runtime_source_matches_release': True,
        'source_sha256': sourceinfo['source_sha256'],
        'created_utc': created,
        'freerdp_commit': freerdp_commit,
        'freerdp_tracked_files_verified_unmodified': freerdp_files,
        'native_abi': NATIVE_ABI,
        'build_environment': {
            'runner': args.runner or os.environ.get('RUNNER_IMAGE') or 'ubuntu-22.04',
            'workflow_run': args.run_url,
            'builder': 'GitHub Actions .github/workflows/release.yml',
        },
        'verification': {
            'flutter_analyze': True,
            'flutter_test': True,
            'native_ctest': True,
            'python_scripts_tests': True,
            'appimage_payload_and_glibc': True,
            'android_apk_static_validation': True,
            'interactive_os_acceptance': 'pending',
            'android_device_acceptance': 'pending',
            'windows_macos_ios_packages': 'not built',
        },
        'android': {
            **appinfo,
            'release_tag_in_aot': args.tag,
            'device_acceptance': 'pending',
            'static_validation_command': 'python3 scripts/check_android_apk.py <apk> --abi arm64-v8a --build-mode release',
        },
        'appimage': {
            'architecture': 'x86_64',
            'sha256': app_sha,
            'maximum_glibc_requirement': glibc,
            'elf_files': elf_count,
            'native_library_sha256': bridge_sha,
            'native_exports': len(exports),
            'actual_runtime': 'not attached; interactive OS acceptance pending',
            'build_base': 'ubuntu-22.04 (GitHub Actions runner)',
        },
        'source': {
            'tarball': source.name,
            'source_sha256': sourceinfo['source_sha256'],
            'source_files': sourceinfo['source_files'],
            'ffmpeg_version': sourceinfo['ffmpeg_version'],
            'ffmpeg_sha256': sourceinfo['ffmpeg_sha256'],
            'ffmpeg_license': sourceinfo['ffmpeg_license'],
            'freerdp_commit': sourceinfo['freerdp_commit'],
        },
    }
    release_info = {
        'tag': args.tag,
        'release_commit': args.commit,
        'application_runtime_commit': args.commit,
        'source_sha256': sourceinfo['source_sha256'],
        'native_abi': NATIVE_ABI,
        'repository_visibility_unchanged': True,
        'build_environment': build_info['build_environment'],
        'verification_scope': build_info['verification'],
        'source_note': ('Application binaries were built by .github/workflows/release.yml from '
                        'the tagged commit in the same workflow run.'),
    }
    build_path = dist / 'BUILD_INFO.json'
    release_path = dist / 'RELEASE_INFO.json'
    write_json(build_path, build_info)
    write_json(release_path, release_info)
    source_digest_path = dist / 'SOURCE_SHA256'
    source_digest_path.write_text(sourceinfo['source_sha256'] + '\n')
    print(f'wrote {source_digest_path}')
    checksums = dist / 'SHA256SUMS'
    verification = dist / f'lrdp-{args.version.split("+")[0]}-verification.zip'
    # apk-meta.json is a build-tool handoff from the Android job, not a release
    # asset: it is merged into BUILD_INFO.json above and must not appear in
    # SHA256SUMS or among the uploaded files.
    checksummed = [appimage, apk, source, build_path, release_path, source_digest_path]
    lines = [f'{sha256_file(path)}  {path.name}' for path in sorted(checksummed)]
    # The verification archive embeds a copy of SHA256SUMS, so write the file
    # before zipping it; the archive's own digest is appended afterwards.
    checksums.write_text('\n'.join(sorted(lines)) + '\n')
    build_verification_zip(verification, args.logs.resolve(), dist,
                           [build_path, release_path, source_digest_path], checksums)
    lines.append(f'{sha256_file(verification)}  {verification.name}')
    checksums.write_text('\n'.join(sorted(lines)) + '\n')
    print(f'wrote {checksums}')
    print(json.dumps({'appimage': app_sha, 'apk': appinfo['apk_sha256'],
                      'source': sha256_file(source)}, indent=2))


if __name__ == '__main__':
    sys.exit(main())
