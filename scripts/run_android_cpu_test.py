#!/usr/bin/env python3
"""Real API26 native-texture idle acceptance on a workspace-owned emulator.

Uses only LRDP_CPU_API26 on ADB 5038 / emulator-5556, a random localhost TLS
port, adb reverse and the standalone frame_rate_fixture.c (no X server).
Prepare first with --prepare-only; build after Android native deps are ready.
JAVA_HOME must select JDK17..24 (the workspace JDK21 is preferred automatically).
"""
from contextlib import ExitStack
from pathlib import Path
import argparse
import base64
import hashlib
import io
import json
import math
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/android-cpu-runtime'
AVD_HOME = OUT / 'avd'
AVD_NAME = 'LRDP_CPU_API26'
AVD_PATH = AVD_HOME / (AVD_NAME + '.avd')


def read_properties(path):
    if not path.is_file():
        return {}
    return {key.strip(): value.strip()
            for line in path.read_text().splitlines()
            if '=' in line and not line.lstrip().startswith('#')
            for key, value in [line.split('=', 1)]}


def tool_paths():
    local = read_properties(ROOT / 'android/local.properties')
    sdk = (os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
           or local.get('sdk.dir'))
    if not sdk:
        raise RuntimeError('Set ANDROID_SDK_ROOT/ANDROID_HOME or local.properties sdk.dir')
    flutter_root = os.environ.get('FLUTTER_ROOT') or local.get('flutter.sdk')
    flutter = str(Path(flutter_root) / 'bin/flutter') if flutter_root else shutil.which('flutter')
    if not flutter:
        raise RuntimeError('Set FLUTTER_ROOT/local.properties flutter.sdk or put flutter on PATH')
    return Path(sdk).expanduser().resolve(), Path(flutter).expanduser().resolve()


SDK, FLUTTER = tool_paths()
ADB = [str(SDK / 'platform-tools/adb'), '-P', '5038', '-s', 'emulator-5556']
PACKAGE = 'dev.lrdp.lrdp'
NDK = '27.0.12077973'


def check(condition, reason):
    if not condition:
        raise AssertionError(reason)


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def android(*parts, check=True, timeout=30):
    return subprocess.run(ADB + list(parts), check=check, timeout=timeout,
                          capture_output=True, text=True)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=8)


def wait_for(ready, reason, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if ready():
            return
        time.sleep(.1)
    raise AssertionError(reason)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def environment():
    local_jdk = OUT / 'jdk21'
    java_home = Path(os.environ.get('JAVA_HOME', str(local_jdk)))
    check((java_home / 'bin/java').is_file(), 'Set JAVA_HOME to an installed JDK17..24')
    version = subprocess.check_output([str(java_home / 'bin/java'), '-version'],
                                      stderr=subprocess.STDOUT, text=True)
    major = int(re.search(r'version "(\d+)', version)[1])
    check(17 <= major <= 24, f'Gradle8.14 needs JDK17..24; found {version}')
    check((SDK / 'ndk' / NDK).is_dir(), f'Required NDK {NDK} is missing')
    env = dict(os.environ, JAVA_HOME=str(java_home), ANDROID_HOME=str(SDK),
               ANDROID_SDK_ROOT=str(SDK), ANDROID_AVD_HOME=str(AVD_HOME),
               ADB_SERVER_SOCKET='tcp:5038', ANDROID_ADB_SERVER_PORT='5038',
               LRDP_OPENSSL_ROOT=str(ROOT / 'build/deps/android-openssl'),
               LRDP_FFMPEG_ROOT=str(ROOT / 'build/deps/ffmpeg/android'),
               LRDP_BUILD_JOBS='3', CMAKE_BUILD_PARALLEL_LEVEL='3')
    env['PATH'] = str(java_home / 'bin') + ':' + str(FLUTTER.parent) + ':' + env['PATH']
    env['GRADLE_OPTS'] = (f'-Dorg.gradle.java.home={java_home} '
                          '-Dorg.gradle.workers.max=3 -Dorg.gradle.jvmargs=-Xmx2g')
    return env, version


def prepare_avd(env):
    AVD_HOME.mkdir(parents=True, exist_ok=True)
    # No global AVD config or existing AVD is modified. This dedicated directory
    # is supplied explicitly to both avdmanager and emulator.
    if not (AVD_PATH / 'config.ini').is_file():
        run([str(SDK / 'cmdline-tools/latest/bin/avdmanager'), 'create', 'avd',
             '--name', AVD_NAME, '--path', str(AVD_PATH),
             '--package', 'system-images;android-26;google_apis;x86_64',
             '--device', 'pixel_2'], input='no\n', text=True, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    config = AVD_PATH / 'config.ini'
    values = read_properties(config)
    ini = AVD_HOME / (AVD_NAME + '.ini')
    pointers = read_properties(ini)
    check(Path(pointers.get('path', '')).resolve() == AVD_PATH.resolve()
          and pointers.get('target') == 'android-26'
          and values.get('abi.type') == 'x86_64'
          and values.get('image.sysdir.1') == 'system-images/android-26/google_apis/x86_64/',
          'Refusing an unexpected AVD config')
    values.update({'AvdId': AVD_NAME, 'avd.ini.displayname': AVD_NAME,
                   'hw.lcd.width': '720', 'hw.lcd.height': '1280',
                   'hw.lcd.density': '320', 'hw.ramSize': '2048',
                   'disk.dataPartition.size': '2G', 'showDeviceFrame': 'no',
                   'fastboot.forceColdBoot': 'yes'})
    config.write_text(''.join(f'{key}={value}\n' for key, value in values.items()))
    return {'name': AVD_NAME, 'path': str(AVD_PATH), 'config_sha256': sha(config)}


def verify_device():
    check(AVD_NAME in android('emu', 'avd', 'name').stdout.splitlines(), 'Wrong AVD on 5556')
    def prop(name):
        return android('shell', 'getprop', name).stdout.strip()
    check(prop('sys.boot_completed') == '1', 'Owned AVD is not booted')
    check(prop('ro.build.version.sdk') == '26', 'Expected API26')
    check(prop('ro.product.cpu.abi') == 'x86_64', 'Expected x86_64')
    check(android('shell', 'id', '-u').stdout.strip() == '2000', 'Use unrooted adbd')
    return {'avd': AVD_NAME, 'api': 26, 'abi': 'x86_64', 'adb_port': 5038,
            'serial': 'emulator-5556', 'shell_uid': 2000,
            'build_fingerprint': prop('ro.build.fingerprint'),
            'display_dump': android('shell', 'dumpsys', 'display').stdout}


def ensure_emulator(env, cleanup):
    devices = run([str(SDK / 'platform-tools/adb'), '-P', '5038', 'devices'],
                  capture_output=True, text=True).stdout
    if not re.search(r'^emulator-5556\s', devices, re.M):
        for port in (5556, 5557):
            with socket.socket() as sock:
                check(sock.connect_ex(('127.0.0.1', port)) != 0,
                      f'Port {port} belongs to an unknown process; refusing to use it')
        log = cleanup.enter_context((OUT / 'emulator.log').open('w'))
        emulator = subprocess.Popen([
            str(SDK / 'emulator/emulator'), '-avd', AVD_NAME, '-port', '5556',
            '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot',
            '-gpu', 'swiftshader_indirect', '-memory', '2048', '-no-metrics'],
            env=env, stdout=log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, emulator)
        wait_for(lambda: android('get-state', check=False).stdout.strip() == 'device',
                 'Owned emulator did not attach; see emulator.log', 120)
        wait_for(lambda: android('shell', 'getprop', 'sys.boot_completed', check=False)
                 .stdout.strip() == '1', 'Owned emulator did not boot', 150)
    device = verify_device()
    (OUT / 'device.json').write_text(json.dumps(device, indent=2) + '\n')
    return device


def apk_inputs():
    paths = subprocess.check_output([
        'git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
    fingerprint = hashlib.sha256(b'LRDP-Android-CPU-APK-v1\0')
    for raw in sorted(set(paths.split(b'\0')) - {b''}):
        name = raw.decode()
        if name.startswith(('lib/', 'assets/', 'android/', 'native/', 'packages/')) or name in (
                'pubspec.yaml', 'pubspec.lock', 'integration_test/android_cpu_test.dart'):
            path = ROOT / name
            if path.is_file():
                fingerprint.update(raw + b'\0' + path.read_bytes() + b'\0')
    fingerprint.update(subprocess.check_output([
        'git', '-C', 'third_party/FreeRDP', 'rev-parse', 'HEAD'], cwd=ROOT))
    for folder in ('build/deps/android-openssl/x86_64/lib', 'build/deps/ffmpeg/android/x86_64/lib'):
        libraries = sorted((ROOT / folder).glob('*.a'))
        check(libraries, f'Android dependencies are not ready: {folder}')
        for path in libraries:
            fingerprint.update(path.name.encode() + sha(path).encode())
    fingerprint.update(NDK.encode())
    return fingerprint.hexdigest()


def build_apk(env, reuse):
    inputs = apk_inputs()
    apk, metadata = OUT / 'cpu-integration-x86_64.apk', OUT / 'APK_BUILD.json'
    if reuse:
        info = json.loads(metadata.read_text())
        check(info['inputs'] == inputs and info['sha256'] == sha(apk),
              'APK inputs changed; rebuild before accepting device evidence')
    else:
        defines = base64.b64encode(
            b'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false').decode()
        with (OUT / 'build.log').open('w') as log:
            run([str(ROOT / 'android/gradlew'), '--no-daemon', '--max-workers=3',
                 '-Dorg.gradle.jvmargs=-Xmx2g', ':app:assembleDebug',
                 '-Ptarget-platform=android-x64', f'-Plrdp.ndkVersion={NDK}',
                 f'-Ptarget={ROOT / "integration_test/android_cpu_test.dart"}',
                 f'-Pdart-defines={defines}'], cwd=ROOT / 'android', env=env,
                stdout=log, stderr=subprocess.STDOUT)
        check(apk_inputs() == inputs, 'Source/dependencies changed during build; rebuild')
        shutil.copy2(ROOT / 'build/app/outputs/apk/debug/app-debug.apk', apk)
        metadata.write_text(json.dumps({'inputs': inputs, 'sha256': sha(apk),
                                       'ndk': NDK}, indent=2) + '\n')
    run([sys.executable, str(ROOT / 'scripts/check_android_apk.py'), str(apk),
         '--abi', 'x86_64', '--integration'], env=env)
    return apk


def read_private(name):
    result = android('exec-out', 'run-as', PACKAGE, 'cat', 'files/' + name, check=False)
    try:
        return json.loads(result.stdout) if result.returncode == 0 and result.stdout.strip() else None
    except json.JSONDecodeError:
        return None


def write_private(name, data):
    check(re.fullmatch(r'cpu-[a-z0-9.-]+', name), 'Invalid control filename')
    run(ADB + ['shell', f"run-as {PACKAGE} sh -c 'cat > files/{name}'"],
        input=data.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)


def screenshot_pixels(meta):
    from PIL import Image
    data = subprocess.check_output(ADB + ['exec-out', 'screencap', '-p'], timeout=25)
    image = Image.open(io.BytesIO(data)).convert('RGB')
    name = meta['stage']
    (OUT / (name + '.png')).write_bytes(data)
    output = android('shell', 'wm', 'size').stdout
    sizes = re.findall(r'(?:Physical|Override) size:\s*(\d+)x(\d+)', output)
    check(sizes, 'Cannot map screenshot to logical display')
    width, height = map(int, sizes[-1])
    sx, sy = image.width / width, image.height / height
    check(abs(sx - sy) < .01, 'Unexpected screenshot aspect ratio')
    observed = []
    for pixel in meta['pixels']:
        point = [math.floor(value * sx) for value in pixel['point']]
        actual = list(image.getpixel(tuple(point)))
        observed.append({'point': point, 'expected': pixel['rgb'], 'actual': actual})
    (OUT / (name + '-pixels.json')).write_text(json.dumps(observed, indent=2) + '\n')
    return all(max(abs(a - b) for a, b in zip(item['actual'], item['expected'])) <= 3
               for item in observed)


def execute(apk, env, cleanup):
    device = ensure_emulator(env, cleanup)
    flags = shlex.split(subprocess.check_output([
        'pkg-config', '--cflags', '--libs', 'freerdp3', 'freerdp-server3', 'winpr3'], text=True))
    fixture = OUT / 'frame_rate_fixture'
    run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
         str(ROOT / 'native/tests/frame_rate_fixture.c'), '-o', str(fixture), *flags])
    temporary = cleanup.enter_context(tempfile.TemporaryDirectory(prefix='lrdp-android-cpu-'))
    private = Path(temporary)
    cert, key = private / 'cert.pem', private / 'key.pem'
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
         '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], capture_output=True)
    key.chmod(0o600)
    der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
    pin = ':'.join(f'{value:02x}' for value in hashlib.sha256(der).digest())
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    android('reverse', f'tcp:{port}', f'tcp:{port}')
    cleanup.callback(android, 'reverse', '--remove', f'tcp:{port}', check=False)
    android('shell', 'am', 'force-stop', PACKAGE)
    installed = android('install', '-r', '-t', str(apk), timeout=90, check=False)
    if 'INSTALL_FAILED_UPDATE_INCOMPATIBLE' in installed.stdout + installed.stderr:
        # verify_device above restricts this cleanup to our own test emulator.
        android('uninstall', PACKAGE)
        installed = android('install', '-r', '-t', str(apk), timeout=90)
    check(installed.returncode == 0 and 'Success' in installed.stdout,
          installed.stdout + installed.stderr)
    android('shell', 'pm', 'clear', PACKAGE)
    android('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'files')
    write_private('cpu-fixture.json', json.dumps({'port': port, 'pin': pin}))
    android('shell', 'wm', 'dismiss-keyguard')
    android('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
    android('shell', 'settings', 'put', 'system', 'user_rotation', '0')
    # Flutter's Android discovery can race SDK component scans. Restrict its SDK
    # view to installed build tools while still addressing exactly emulator5556.
    view = OUT / 'sdk-view'
    for relative in ('build-tools/36.0.0', 'platforms/android-36', 'platform-tools',
                     'emulator', 'cmdline-tools', 'ndk', 'cmake', 'licenses'):
        destination = view / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists() and (SDK / relative).exists():
            destination.symlink_to(SDK / relative, target_is_directory=True)
    drive_env = dict(env, ANDROID_HOME=str(view), ANDROID_SDK_ROOT=str(view))
    log = cleanup.enter_context((OUT / 'driver.log').open('w'))
    driver = subprocess.Popen([
        str(FLUTTER), 'drive', '--no-pub', '--keep-app-running', '-d', 'emulator-5556',
        '--target', 'integration_test/android_cpu_test.dart', '--driver',
        'test_driver/android_runtime.dart', '--use-application-binary', str(apk)],
        cwd=ROOT, env=drive_env, stdout=log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, driver)
    cleanup.callback(android, 'shell', 'am', 'force-stop', PACKAGE, check=False)
    server = None
    seen = []
    def start_server(name):
        server_log = cleanup.enter_context((OUT / (name + '-server.log')).open('w'))
        process = subprocess.Popen([str(fixture), str(port), str(cert), str(key)],
                                   env=dict(env, WLOG_LEVEL='WARN'), stdout=server_log,
                                   stderr=subprocess.STDOUT)
        cleanup.callback(stop, process)
        def listening():
            check(process.poll() is None, f'{name} producer exited before listening')
            # A TCP connect would consume this single-peer fixture.
            return any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                       for line in Path('/proc/net/tcp').read_text().splitlines()[1:])
        wait_for(listening, 'Private fixture did not listen')
        return process
    deadline = time.monotonic() + 240
    while driver.poll() is None and time.monotonic() < deadline:
        meta = read_private('cpu-stage.json')
        if meta and meta['stage'] not in seen:
            name = meta['stage']
            (OUT / (name + '.json')).write_text(json.dumps(meta, indent=2) + '\n')
            if name == 'probe-ready':
                server = start_server('probe')
            elif name == 'certificate-probed':
                check(server is not None and server.wait(timeout=5) == 1,
                      'Certificate probe producer must reject the unaccepted connection')
                server = start_server('accepted')
            elif name.endswith('-pixels'):
                check('Settled disjoint damage then silence' in
                      (OUT / 'accepted-server.log').read_text(), 'Producer did not settle')
                wait_for(lambda: screenshot_pixels(meta), 'Wrong native texture pixels: ' + name, 8)
            elif name == 'input-ack':
                check(server is not None and server.wait(timeout=5) == 0,
                      'Producer did not acknowledge A release')
                check('client acknowledged=1' in (OUT / 'accepted-server.log').read_text(),
                      'Missing fixture input acknowledgment')
            else:
                raise AssertionError('Unknown test stage ' + name)
            seen.append(name)
            write_private('cpu-' + name + '.ack', '1')
            print('PASS Android CPU stage:', name, flush=True)
        result = read_private('cpu-result.json')
        if result and not result['passed']:
            (OUT / 'device-result.json').write_text(json.dumps(result, indent=2) + '\n')
            raise AssertionError('Device test failed: ' + str(result.get('error')))
        time.sleep(.1)
    check(driver.poll() is not None, 'Flutter driver timed out')
    check(driver.wait(timeout=10) == 0, 'Integration driver failed; see driver.log')
    result = read_private('cpu-result.json')
    check(result and result['passed'], 'No successful device result')
    check(seen == ['probe-ready', 'certificate-probed', 'silent-pixels',
                   'recreated-pixels', 'resumed-pixels', 'input-ack'], 'Missing acceptance stage')
    with zipfile.ZipFile(apk) as archive:
        library_sha = hashlib.sha256(archive.read('lib/x86_64/liblrdp.so')).hexdigest()
    result.update(device=device, stages=seen, apk_sha256=sha(apk),
                  apk_build=json.loads((OUT / 'APK_BUILD.json').read_text()),
                  runner_sha256=sha(Path(__file__).resolve()),
                  integration_test_sha256=sha(ROOT / 'integration_test/android_cpu_test.dart'),
                  library_sha256=library_sha,
                  producer_source_sha256=sha(ROOT / 'native/tests/frame_rate_fixture.c'),
                  root_used=False, physical_device_tested=False, server_exit_code=server.returncode,
                  scope='Actual Android API26 x86_64 emulator, Surface/EGL native texture and '
                        'system screenshot pixels; private TLS 320x240 BGRA 240Hz producer. '
                        'Choreographer/display limits actual uploads; no 120Hz screen claim. '
                        'Counters measure draw attempts/uploads, not whole-process CPU or AVC.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-only', action='store_true', help='Prepare the dedicated AVD only')
    parser.add_argument('--build-only', action='store_true', help='Build APK without device operations')
    parser.add_argument('--reuse-apk', action='store_true', help='Reuse only if source/dependency hashes match')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    verdict = {'passed': False}
    try:
        env, java = environment()
        verdict.update(java=java, avd=prepare_avd(env))
        if args.prepare_only:
            prepared = {'prepared': True, 'device_tested': False,
                        'java': java, 'avd': verdict['avd']}
            (OUT / 'PREPARED.json').write_text(json.dumps(prepared, indent=2) + '\n')
            print('Prepared dedicated AVD:', AVD_PATH)
            return
        apk = build_apk(env, args.reuse_apk)
        if args.build_only:
            print('Built Android CPU integration APK:', apk)
            return
        with ExitStack() as cleanup:
            verdict.update(execute(apk, env, cleanup))
    except Exception as error:
        verdict['error'] = f'{type(error).__name__}: {error}'
    (OUT / 'VERDICT.json').write_text(json.dumps(verdict, indent=2) + '\n')
    print(json.dumps(verdict, indent=2))
    if not verdict['passed']:
        sys.exit(1)


if __name__ == '__main__':
    main()
