#!/usr/bin/env python3
"""Cross-build the production Windows video plugin and a private Flutter host.

This Debug acceptance host does not replace the MSVC main-app build. It imports
the real Flutter Windows engine and plugin DLL; Dart uses the real FFI core.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

root = Path(__file__).resolve().parent.parent
flutter = Path(os.environ.get('FLUTTER_ROOT', '/opt/flutter')).resolve()
engine = (flutter / 'bin/cache/engine.stamp').read_text().strip()
cache = root / 'build/deps/flutter-windows' / engine
out = root / 'build/windows-video-host'
out.mkdir(parents=True, exist_ok=True)


def sha(path):
    with Path(path).open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def fetch(directory, relative, archive_name):
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / archive_name
    url = f'https://storage.googleapis.com/flutter_infra_release/flutter/{engine}/{relative}'
    if not archive.exists():
        with tempfile.TemporaryDirectory(prefix='download-', dir=directory) as temporary:
            pending = Path(temporary) / archive_name
            with urllib.request.urlopen(url, timeout=60) as source, pending.open('wb') as target:
                shutil.copyfileobj(source, target)
            with zipfile.ZipFile(pending) as package:
                assert package.testzip() is None
            pending.replace(archive)
    with zipfile.ZipFile(archive) as package:
        package.extractall(directory)
    metadata = {'url': url, 'engine': engine, 'sha256': sha(archive)}
    (directory / 'LRDP_DOWNLOAD.json').write_text(json.dumps(metadata, indent=2) + '\n')
    return metadata


downloads = [fetch(cache, 'windows-x64/artifacts.zip', 'artifacts.zip'),
             fetch(cache / 'debug', 'windows-x64-debug/windows-x64-flutter.zip', 'engine.zip')]
headers = cache / 'debug'
platform = flutter / 'engine/src/flutter/shell/platform'
wrapper = platform / 'common/client_wrapper'
if not (wrapper / 'standard_codec.cc').is_file():
    raise SystemExit('This cross-build needs the matching Flutter monorepo client wrapper sources')
for name in ('flutter_texture_registrar.h', 'flutter_plugin_registrar.h', 'flutter_messenger.h'):
    assert (headers / name).read_text() == (platform / 'common/public' / name).read_text(), name
assert (headers / 'flutter_windows.h').read_text() == (platform / 'windows/public/flutter_windows.h').read_text()


def run(command, name):
    with (out / name).open('w') as log:
        result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f'{name}:\n' + (out / name).read_text()[-7000:])


run(['cmake', '-S', 'native', '-B', 'build/windows-x64',
     '-DLRDP_FLUTTER_TEXTURE_HEADERS=' + str(headers)], 'native-configure.log')
run(['cmake', '--build', 'build/windows-x64', '--target', 'lrdp_core',
     'lrdp_windows_video_test', '-j', os.environ.get('LRDP_BUILD_JOBS', '3')], 'native-build.log')
includes = []
for path in (headers, wrapper / 'include', wrapper / 'include/flutter', wrapper,
             platform / 'windows/client_wrapper/include', root / 'native/include',
             root / 'packages/lrdp_native/windows', root / 'packages/lrdp_native/windows/include'):
    # Preserve strict diagnostics for LRDP while treating SDK templates as SDK
    # headers (GCC 16 diagnoses upstream's redundant std::move expressions).
    includes += ['-I' if path.is_relative_to(root / 'native') or
                 path.is_relative_to(root / 'packages') else '-isystem', str(path)]
compiler = ['x86_64-w64-mingw32-g++', '-std=c++17', '-O0', '-g', '-Wall', '-Wextra',
            '-Werror', '-D_WIN32_WINNT=0x0A00', '-static', '-static-libgcc', '-static-libstdc++']
production = [root / 'packages/lrdp_native/windows' / name
              for name in ('lrdp_native_plugin.cpp', 'video_texture.cc')]
common = [wrapper / name for name in ('core_implementations.cc', 'standard_codec.cc', 'plugin_registrar.cc')]
plugin = out / 'lrdp_native_plugin.dll'
objects = out / 'objects'
objects.mkdir(exist_ok=True)
dependencies = [*production, *common,
                *sorted((root / 'packages/lrdp_native/windows').rglob('*.h')),
                *sorted((wrapper / 'include').rglob('*.h'))]
dependency_hash = hashlib.sha256(''.join(sha(path) for path in dependencies).encode()).hexdigest()


def compile_object(source):
    destination = objects / (source.name + '.o')
    stamp = objects / (source.name + '.json')
    options = compiler + includes + ['-DLRDP_NATIVE_PLUGIN_IMPL']
    if source in common:
        # The SDK includes its own headers by source-relative paths. Keep the
        # known GCC diagnostic visible without changing SDK or LRDP policy.
        options += ['-Wno-error=pessimizing-move']
    command = options + ['-c', str(source), '-o', str(destination)]
    fingerprint = hashlib.sha256(json.dumps([command, engine, dependency_hash]).encode()).hexdigest()
    if stamp.exists() and destination.exists():
        previous = json.loads(stamp.read_text())
        if previous['inputs'] == fingerprint and previous['sha256'] == sha(destination):
            return destination
    run(command, source.name + '-compile.log')
    stamp.write_text(json.dumps({'inputs': fingerprint, 'sha256': sha(destination)}) + '\n')
    return destination


with ThreadPoolExecutor(max_workers=3) as executor:
    compiled = list(executor.map(compile_object, production + common))
run(compiler + ['-shared'] + [str(path) for path in compiled] + [str(headers / 'flutter_windows.dll.lib'),
     str(root / 'build/windows-x64/liblrdp.dll.a'), '-luser32',
     '-Wl,--out-implib,' + str(out / 'liblrdp_native_plugin.dll.a'), '-o', str(plugin)], 'plugin-compile.log')
host = out / 'video_host.exe'
run(compiler + includes + ['-municode', str(root / 'native/tests/windows_video_host.cc'),
    str(headers / 'flutter_windows.dll.lib'), str(out / 'liblrdp_native_plugin.dll.a'),
    '-luser32', '-o', str(host)], 'host-compile.log')

assets = out / 'flutter_assets'
assets.mkdir(exist_ok=True)
dart = flutter / 'bin/cache/dart-sdk/bin/dartaotruntime'
run([str(dart), str(flutter / 'bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot'),
     '--sdk-root', str(flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk'),
     '--target', 'flutter', '--no-link-platform', '--packages', '.dart_tool/package_config.json',
     '--output-dill', str(assets / 'kernel_blob.bin'), 'test_driver/windows_video.dart'], 'kernel-compile.log')
for name in ('isolate_snapshot.bin', 'vm_isolate_snapshot.bin'):
    shutil.copy2(cache / name, assets / name)
for source, destination in ((headers / 'flutter_windows.dll', out / 'flutter_windows.dll'),
                            (cache / 'icudtl.dat', out / 'icudtl.dat'),
                            (root / 'build/windows-x64/lrdp.dll', out / 'lrdp.dll')):
    shutil.copy2(source, destination)

sources = ['test_driver/windows_video.dart', 'native/tests/windows_video_host.cc',
           'native/tests/windows_video_texture_test.cc', 'lib/rdp/rdp_session.dart',
           'lib/rdp/native_video.dart', 'lib/ui/remote_surface.dart',
           'packages/lrdp_native/windows/video_texture.h',
           'packages/lrdp_native/windows/include/lrdp_native/lrdp_native_plugin.h',
           'packages/lrdp_native/windows/lrdp_native_plugin.cpp',
           'packages/lrdp_native/windows/video_texture.cc']
metadata = {'target': 'MinGW x64 Debug Flutter Windows video acceptance host',
            'main_application': False, 'physical_windows': False, 'flutter_engine': engine,
            'downloads': downloads, 'source_files_sha256': {name: sha(root / name) for name in sources},
            'artifacts_sha256': {str(path.relative_to(out)): sha(path) for path in
                                (host, plugin, out / 'lrdp.dll', out / 'flutter_windows.dll',
                                 assets / 'kernel_blob.bin')}}
(out / 'BUILD_INFO.json').write_text(json.dumps(metadata, indent=2) + '\n')
print('PASS: actual Windows plugin DLL, Flutter engine host and portable Debug kernel built', flush=True)
