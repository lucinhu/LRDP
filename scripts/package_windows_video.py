#!/usr/bin/env python3
"""Package the verified Windows core/video plugin development kit, not an app."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import zipfile

root = Path(__file__).resolve().parent.parent
build = root / 'build/windows-video-host'
out = Path(os.environ.get('LRDP_DISTRIBUTIONS_DIR',
    root / 'build/distributions/windows-native-video')).resolve()
out.mkdir(parents=True, exist_ok=True)


def sha(path):
    with Path(path).open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def read(path):
    return json.loads((root / path).read_text())


metadata = read('build/windows-video-host/BUILD_INFO.json')
for name, expected in metadata['source_files_sha256'].items():
    assert sha(root / name) == expected, 'Changed verified source: ' + name
for name, expected in metadata['artifacts_sha256'].items():
    assert sha(build / name) == expected, 'Changed verified artifact: ' + name
reports = {}
for mode in ('native', 'fallback'):
    folder = root / 'build/windows-video-runtime' / mode
    report = json.loads((folder / 'VERDICT.json').read_text())
    assert report['passed'] and report['reconnections'] == 3 and len(report['cases']) == 6
    assert report['native_texture'] == (mode == 'native')
    assert report['wine_legacy_allocator'] and not report['engine_file_modified']
    assert report['build'] == metadata
    assert 'engine and plugin teardown returned' in (folder / 'flutter.log').read_text()
    assert all(value == 0 for name, value in report['diagnostics'].items() if name != 'uploadFailures')
    if mode == 'native':
        assert report['decoded_frames_initial'] == report['decoded_frames_final'] == 0
    else:
        assert report['diagnostics']['uploadFailures'] == 4
    reports[mode] = report
core = build / 'lrdp.dll'
plugin = build / 'lrdp_native_plugin.dll'
protocol = read('build/windows-runtime/winpr/VERDICT.json')
assert protocol['result'] == 'passed' and protocol['core_sha256'] == sha(core)
assert not subprocess.check_output(['git', '-C', 'third_party/FreeRDP', 'status', '--porcelain'], cwd=root)
commit = subprocess.check_output(['git', '-C', 'third_party/FreeRDP', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
paths = sorted(set(subprocess.check_output(['git', 'ls-files', '--cached', '--others',
    '--exclude-standard', '-z'], cwd=root).split(b'\0')) - {b''})
fingerprint = hashlib.sha256(b'LRDP-source-v1\0')
for raw in paths:
    data = commit.encode() if raw == b'third_party/FreeRDP' else (root / raw.decode()).read_bytes()
    fingerprint.update(raw + b'\0' + hashlib.sha256(data).digest() + b'\0')
imports = {}
for binary in (core, plugin):
    description = subprocess.check_output(['x86_64-w64-mingw32-objdump', '-p', str(binary)], text=True)
    assert 'file format pei-x86-64' in description
    imports[binary.name] = re.findall(r'DLL Name: (\S+)', description)
    assert not any(name.lower().startswith(('libgcc', 'libwinpthread', 'libstdc++', 'libssl',
        'libcrypto', 'freerdp', 'winpr')) for name in imports[binary.name]), imports
    if binary == plugin:
        assert 'LrdpNativePluginRegisterWithRegistrar' in description
version = re.search(r'^version:\s*([^+\s]+)', (root / 'pubspec.yaml').read_text(), re.M).group(1)
name = f'lrdp-{version}-windows-x64-video-debug'
info = {'status': 'development kit; not an application installer', 'native_abi': 5,
        'source_sha256': fingerprint.hexdigest(), 'source_files': len(paths),
        'freerdp_commit': commit, 'freerdp_source_modified': False,
        'core_sha256': sha(core), 'plugin_sha256': sha(plugin), 'imports': imports,
        'build': metadata, 'display_verification': reports, 'core_protocol': protocol,
        'scope': ['MinGW x64 Debug core and native pixel buffer plugin',
                  'Real official Flutter Windows Debug engine under Wine with explicit legacy allocator test-host adapter',
                  'No production-plugin, FreeRDP or engine disk-file modification for that adapter',
                  'MSVC/main application/Windows SSPI/Credential Manager/physical Windows GPU remain pending',
                  'Native CPU conversion/upload; no shared D3D surfaces or hardware H.264']}
readme = '''LRDP Windows x64 core and native video development kit

This is NOT a standalone RDP application or an installer. It contains the
matching MinGW Debug lrdp.dll and lrdp_native_plugin.dll, C ABI v5 header,
plugin registration header, source bindings and verification records.
The host application must provide its matching Flutter Windows engine.
Build the full main application with Visual Studio following docs/BUILDING.md.

Actual Flutter Windows pixels, XOR, color/orientation, zoom, freeze/resume,
CPU recovery, reconnect cleanup and engine shutdown passed under Wine 11.20.
The display test explicitly selects Dart's legacy allocator in its test host
because Wine's default VirtualAlloc2 path assigned overlapping live regions.
The production plugin, FreeRDP source and engine disk file are unchanged by
this test-host adapter. This is not evidence for physical Windows or MSVC.

Keep this kit with the matching lrdp-0.1.0-source.tar.gz in the same delivery
folder. It contains complete LRDP/adaptor and unmodified FreeRDP sources,
the exact LGPL FFmpeg source archive and build configuration for relinking.
Preserve all licenses and NOTICE. See BUILD_INFO.json for hashes and scope.
'''
files = [(core, 'lrdp.dll'), (plugin, 'lrdp_native_plugin.dll'),
         (root / 'native/include/lrdp.h', 'include/lrdp.h'),
         (root / 'packages/lrdp_native/windows/include/lrdp_native/lrdp_native_plugin.h',
          'include/lrdp_native/lrdp_native_plugin.h'),
         (root / 'lib/rdp/native_bindings.dart', 'dart/native_bindings.dart'),
         (root / 'lib/rdp/native_video.dart', 'dart/native_video.dart')]
for path in (root / 'LICENSE', root / 'NOTICE', root / 'docs/BUILDING.md', root / 'docs/VERIFICATION.md'):
    files.append((path, str(path.relative_to(root))))
for path in list((root / 'assets/licenses').glob('*.txt')) + list((root / 'licenses/windows').glob('*.txt')):
    files.append((path, 'licenses/' + path.name))
flutter = Path(os.environ.get('FLUTTER_ROOT', '/opt/flutter'))
files.append((flutter / 'LICENSE', 'licenses/Flutter.txt'))
destination = out / (name + '.zip')
with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for path, relative in files:
        archive.write(path, name + '/' + relative)
    archive.writestr(name + '/BUILD_INFO.json', json.dumps(info, indent=2) + '\n')
    archive.writestr(name + '/README.txt', readme)
(out / 'BUILD_INFO-WINDOWS.json').write_text(json.dumps(info, indent=2) + '\n')
(out / (destination.name + '.sha256')).write_text(sha(destination) + '  ' + destination.name + '\n')
print(destination)
