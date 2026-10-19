#!/usr/bin/env python3
"""Build the real Windows main application from Linux with clang-cl.

Uses official Microsoft headers/libraries, the matching Flutter Release engine,
and a separately built MinGW C ABI core. Wine is used only to run gen_snapshot.
The optional Wine allocator helper is never included in the application bundle.
"""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
from urllib.parse import unquote, urljoin, urlparse
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def sha(path):
    with Path(path).open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def win(path):
    return 'Z:' + str(Path(path).resolve()).replace('/', '\\')


def cmake_value(value):
    # Bracket literals preserve spaces and Windows resource backslashes.
    value = str(value)
    assert ']=]' not in value
    return '[=[' + value + ']=]'


def build_inputs():
    files = {ROOT / 'pubspec.yaml', ROOT / 'pubspec.lock', ROOT / 'native/CMakeLists.txt'}
    for directory in ('lib', 'assets', 'native/src', 'native/include', 'native/windows_app',
                      'packages/lrdp_native', 'windows'):
        for path in (ROOT / directory).rglob('*'):
            if path.is_file() and not {'build', 'ephemeral', '.dart_tool', '.git'}.intersection(
                    path.relative_to(ROOT / directory).parts):
                files.add(path)
    return {str(path.relative_to(ROOT)): sha(path) for path in sorted(files)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter-root', type=Path,
                        default=Path(os.environ.get('FLUTTER_ROOT', '/opt/flutter')))
    parser.add_argument('--xwin-root', type=Path, default=ROOT / 'build/deps/xwin/sysroot')
    parser.add_argument('--core-dir', type=Path, default=ROOT / 'build/windows-x64')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/windows-app-clang')
    parser.add_argument('--wine-legacy-allocator', action='store_true',
                        help='Explicit Wine-only gen_snapshot allocator compatibility; not shipped')
    args = parser.parse_args()
    flutter = args.flutter_root.resolve()
    sdk = args.xwin_root.resolve()
    core = args.core_dir.resolve()
    out = args.output.resolve()
    if not out.is_relative_to(ROOT / 'build'):
        parser.error('Keep generated files under this workspace build/ directory')
    out.mkdir(parents=True, exist_ok=True)
    (out / 'BUILD_INFO.json').unlink(missing_ok=True)
    bundle = out / 'bundle'
    bundle.mkdir(exist_ok=True)

    def run(command, name, *, env=None, cwd=ROOT):
        print(name, flush=True)
        with (out / name).open('w') as log:
            result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'{name} failed ({result.returncode}):\n' +
                               (out / name).read_text()[-7000:])

    assert not subprocess.check_output(['git', '-C', str(ROOT / 'third_party/FreeRDP'),
                                        'status', '--porcelain'])
    engine = (flutter / 'bin/cache/engine.stamp').read_text().strip()
    engine_dir = ROOT / 'build/deps/flutter-windows' / engine / 'release'
    archive = engine_dir / 'engine.zip'
    expected = os.environ.get('LRDP_WINDOWS_ENGINE_SHA256',
        'dc5bc32e8a01c8aa92c1105005065c05d8963d12939a2f2ef32e6d5150c5c63c'
        if engine == '616aa037ef00bf7a8c62500da7dec7f1c21ad59b' else '')
    if not archive.is_file() or not expected or sha(archive) != expected:
        raise RuntimeError('Obtain and review the matching official Windows Release engine archive; '
                           'see docs/BUILDING.md (LRDP_WINDOWS_ENGINE_SHA256 for a new SDK)')
    with zipfile.ZipFile(archive) as package:
        assert package.testzip() is None
        for name in ('flutter_windows.dll', 'flutter_windows.dll.lib', 'flutter_windows.h',
                     'flutter_export.h', 'flutter_messenger.h', 'flutter_plugin_registrar.h',
                     'flutter_texture_registrar.h', 'gen_snapshot.exe', 'LICENSE.windows_flutter.md'):
            data = package.read(name)
            assert (engine_dir / name).read_bytes() == data, name
    platform = flutter / 'engine/src/flutter/shell/platform'
    for name in ('flutter_texture_registrar.h', 'flutter_plugin_registrar.h', 'flutter_messenger.h'):
        assert (engine_dir / name).read_text() == (platform / 'common/public' / name).read_text(), name
    assert (engine_dir / 'flutter_windows.h').read_text() == (
        platform / 'windows/public/flutter_windows.h').read_text()
    assert (core / 'lrdp.dll').is_file() and (core / 'liblrdp.dll.a').is_file()
    msvc_versions = sorted((sdk / 'VC/Tools/MSVC').iterdir(), key=lambda p: tuple(map(int, p.name.split('.'))))
    sdk_versions = sorted((sdk / 'Windows Kits/10/Lib').iterdir(), key=lambda p: tuple(map(int, p.name.split('.'))))
    msvc_version, sdk_version = msvc_versions[-1].name, sdk_versions[-1].name
    assert (sdk / 'VC/Tools/MSVC' / msvc_version / 'include/atlbase.h').is_file(), 'xwin must include ATL'

    # An empty process-local discovery directory lets Flutter report no native
    # VS compiler on Linux. No fake vswhere executable or global Flutter setting.
    with tempfile.TemporaryDirectory(prefix='lrdp-windows-discovery-') as discovery:
        env = dict(os.environ, **{'PROGRAMFILES(X86)': discovery})
        run([flutter / 'bin/flutter', 'pub', 'get'], 'pub-get.log', env=env)
        initial = build_inputs()
        config = ROOT / '.dart_tool/package_config.json'
        plugins = {row['name']: Path(unquote(urlparse(urljoin(config.as_uri(), row['rootUri'])).path))
                   for row in json.loads(config.read_text())['packages']}
        run([flutter / 'bin/flutter', 'build', 'bundle', '--release', '--target-platform', 'windows-x64',
             '--target', 'lib/main.dart', '--asset-dir', out / 'flutter_assets'], 'dart-assets.log', env=env)
        run([flutter / 'bin/flutter', 'assemble', '--output', out / 'dart',
             '-dTargetPlatform=windows-x64',
             '-dBuildMode=release', '-dTargetFile=lib/main.dart', '-dTrackWidgetCreation=false',
             'kernel_snapshot_program'], 'dart-kernel.log', env=env)
    assert initial == build_inputs(), 'Production sources changed during the build'
    native_assets = json.loads((out / 'flutter_assets/NativeAssetsManifest.json').read_text())
    assert not native_assets['native-assets'], 'Review and bundle newly required Windows native assets'
    build_id = (out / 'dart/.last_build_id').read_text().strip()
    assert re.fullmatch('[a-f0-9]{32}', build_id)
    kernel = ROOT / '.dart_tool/flutter_build' / build_id / 'app.dill'
    assert kernel.is_file()
    # Flutter's output list can be empty on a cache hit. Its successful target
    # and .last_build_id identify the kernel; verify the current main/UI source
    # embedded by the frontend instead of mistaking a cache hit for a failure.
    kernel_data = kernel.read_bytes()
    for name in ('lib/main.dart', 'lib/ui/mobile_keyboard.dart', 'lib/ui/remote_view.dart'):
        assert (ROOT / name).read_bytes() in kernel_data, 'Stale kernel source: ' + name

    patches = ROOT / 'native/tests/windows_app'
    patch_info = json.loads((patches / 'PATCHES.json').read_text())
    plugin_inputs = {}
    for name in ('file_selector_windows', 'flutter_secure_storage_windows', 'share_plus', 'url_launcher_windows', 'jni'):
        source = plugins[name]
        plugin_inputs[name] = {str(p.relative_to(source)): sha(p)
                              for p in sorted((source / 'windows').rglob('*')) if p.is_file()}
        if name not in patch_info:
            continue
        info = patch_info[name]
        actual_version = re.search(r'^version:\s*(\S+)', (source / 'pubspec.yaml').read_text(), re.M)[1]
        assert actual_version == info['version'], f'Review {name} patch for version {actual_version}'
        for file, record in info['files'].items():
            assert sha(source / file) == record['original_sha256'], file
        staged = out / 'patched' / name
        shutil.copytree(source / 'windows', staged / 'windows', dirs_exist_ok=True)
        run(['patch', '--batch', '--fuzz=0', '-p1', '-i', patches / (name + '.patch')],
            name + '-patch.log', cwd=staged)
        for file, record in info['files'].items():
            assert sha(staged / file) == record['patched_sha256'], file
        plugins[name] = staged

    resource = (ROOT / 'windows/runner/Runner.rc').read_text()
    assert resource.count('resources\\\\app_icon.ico') == 1
    resource = resource.replace('resources\\\\app_icon.ico',
                                str(ROOT / 'windows/runner/resources/app_icon.ico'))
    (out / 'Runner.rc').write_text(resource)
    version = re.search(r'^version:\s*([^+\s]+)(?:\+(\d+))?',
                        (ROOT / 'pubspec.yaml').read_text(), re.M)
    major, minor, patch = version[1].split('.')
    values = {'LRDP_FLUTTER_ROOT': flutter, 'LRDP_FLUTTER_ENGINE': engine_dir,
              'LRDP_APP_BUNDLE': bundle, 'LRDP_CORE_DIR': core,
              'LRDP_RUNNER_RESOURCE': out / 'Runner.rc', 'LRDP_VERSION': version[1],
              'LRDP_VERSION_MAJOR': major, 'LRDP_VERSION_MINOR': minor,
              'LRDP_VERSION_PATCH': patch, 'LRDP_VERSION_BUILD': version[2] or '1'}
    for name in ('file_selector_windows', 'flutter_secure_storage_windows', 'share_plus', 'url_launcher_windows', 'jni'):
        values['LRDP_PLUGIN_' + name] = plugins[name]
    (out / 'inputs.cmake').write_text(''.join(f'set({k} {cmake_value(v)})\n' for k, v in values.items()))
    run(['cmake', '-S', ROOT / 'native/windows_app', '-B', out / 'cmake', '-G', 'Ninja',
         '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_TOOLCHAIN_FILE=' + str(ROOT / 'cmake/toolchains/windows-clang-cl.cmake'),
         '-DLRDP_XWIN_ROOT=' + str(sdk), '-DLRDP_MSVC_VERSION=' + msvc_version,
         '-DLRDP_WINDOWS_SDK_VERSION=' + sdk_version, '-DLRDP_APP_INPUTS=' + str(out / 'inputs.cmake')], 'native-configure.log')
    run(['cmake', '--build', out / 'cmake', '-j', os.environ.get('LRDP_BUILD_JOBS', '3')], 'native-build.log')

    tools = out / 'tools'
    tools.mkdir(exist_ok=True)
    compiler = ['x86_64-w64-mingw32-g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                '-O2', '-static', '-static-libgcc', '-static-libstdc++', '-D_WIN32_WINNT=0x0A00']
    for source, options, output in [('wine_launch.cpp', ['-municode'], 'wine_launch.exe'),
                                    ('wine_legacy_allocator.cpp', ['-shared'], 'wine_legacy_allocator.dll'),
                                    ('close_app.cpp', [], 'close_app.exe')]:
        run(compiler + options + [patches / source, '-o', tools / output], source + '-build.log')
    data = bundle / 'data'
    data.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='lrdp-windows-snapshot-') as temporary, ExitStack() as cleanup:
        private = Path(temporary)
        display = next(i for i in range(101, 201) if not Path(f'/tmp/.X11-unix/X{i}').exists())
        env = dict(os.environ, DISPLAY=f':{display}', WINEPREFIX=str(private / 'wine'),
                   WINEARCH='win64', WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=',
                   XDG_CONFIG_HOME=str(private / 'config'), XDG_DATA_HOME=str(private / 'data'))
        log = cleanup.enter_context((out / 'snapshot.log').open('w'))
        desktop = subprocess.Popen(['Xvnc', env['DISPLAY'], '-geometry', '1280x800', '-depth', '24',
            '-SecurityTypes', 'None', '-noreset', '-rfbport', '-1', '-rfbunixpath', str(private / 'display.sock'),
            '-rfbunixmode', '0600', '-nolisten', 'tcp'], env=env, stdout=log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, desktop)
        deadline = time.monotonic() + 30
        while not Path(f'/tmp/.X11-unix/X{display}').exists():
            assert desktop.poll() is None and time.monotonic() < deadline
            time.sleep(.1)
        cleanup.callback(subprocess.run, ['wineserver', '-k'], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        subprocess.run(['wineboot', '--init'], env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
        command = ['wine']
        if args.wine_legacy_allocator:
            command += [str(tools / 'wine_launch.exe'), win(tools / 'wine_legacy_allocator.dll')]
        command += [win(engine_dir / 'gen_snapshot.exe'), '--deterministic', '--snapshot_kind=app-aot-elf',
                    '--strip', '--elf=' + win(data / 'app.so'), win(kernel)]
        print('Windows gen_snapshot (explicit Wine legacy allocator)' if args.wine_legacy_allocator
              else 'Windows gen_snapshot (unmodified Wine)', flush=True)
        subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
        assert (data / 'app.so').read_bytes().startswith(b'\x7fELF')
    shutil.copytree(out / 'flutter_assets', data / 'flutter_assets', dirs_exist_ok=True)
    source_assets = {str(p.relative_to(out / 'flutter_assets')): sha(p)
                     for p in (out / 'flutter_assets').rglob('*') if p.is_file()}
    bundled_assets = {str(p.relative_to(data / 'flutter_assets')): sha(p)
                      for p in (data / 'flutter_assets').rglob('*') if p.is_file()}
    assert source_assets == bundled_assets, 'Stale bundled assets; choose a fresh output directory'
    shutil.copy2(engine_dir / 'flutter_windows.dll', bundle / 'flutter_windows.dll')
    shutil.copy2(core / 'lrdp.dll', bundle / 'lrdp.dll')
    icu = engine_dir.parent / 'icudtl.dat'
    assert icu.is_file(), 'Obtain matching Windows artifacts.zip beside the engine directory'
    shutil.copy2(icu, data / 'icudtl.dat')
    assert not list(bundle.glob('wine*')) and not (bundle / 'close_app.exe').exists()
    assert initial == build_inputs(), 'Production sources changed during the build'
    for name, hashes in plugin_inputs.items():
        original = next(Path(unquote(urlparse(urljoin(config.as_uri(), row['rootUri'])).path))
                        for row in json.loads(config.read_text())['packages'] if row['name'] == name)
        assert hashes == {str(p.relative_to(original)): sha(p)
                          for p in sorted((original / 'windows').rglob('*')) if p.is_file()}, name
    assert not subprocess.check_output(['git', '-C', str(ROOT / 'third_party/FreeRDP'), 'status', '--porcelain'])
    native_type = re.search(r'^CMAKE_BUILD_TYPE:STRING=(.*)$',
                           (core / 'CMakeCache.txt').read_text(), re.M)[1]
    info = {'entrypoint': 'lib/main.dart Release AOT', 'main_application': True,
            'physical_windows': False, 'ui_compiler': 'clang-cl with official MSVC CRT / SDK / ATL',
            'native_core_compiler': 'MinGW C ABI DLL', 'native_core_build_type': native_type,
            'flutter_engine': engine, 'engine_archive_sha256': expected,
            'msvc_version': msvc_version, 'windows_sdk_version': sdk_version,
            'snapshot_compiler_wine_legacy_allocator': args.wine_legacy_allocator,
            'compatibility_helpers_shipped': False, 'source_files_sha256': initial,
            'plugin_sources_sha256': plugin_inputs, 'staged_plugin_patches': patch_info,
            'kernel_sha256': sha(kernel),
            'artifacts_sha256': {str(p.relative_to(bundle)): sha(p)
                                 for p in sorted(bundle.rglob('*')) if p.is_file()},
            'freerdp_commit': subprocess.check_output(['git', '-C', str(ROOT / 'third_party/FreeRDP'),
                                                      'rev-parse', 'HEAD'], text=True).strip(),
            'freerdp_source_modified': False, 'runtime_acceptance': 'Not performed by the build script'}
    (out / 'BUILD_INFO.json').write_text(json.dumps(info, indent=2) + '\n')
    print('Built real Windows main application:', bundle, flush=True)


if __name__ == '__main__':
    main()
