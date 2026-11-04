#!/usr/bin/env python3
"""Private Android AVC420 runtime on an owned x86_64 AVD, ADB5038/5556.

--prepare-only creates the AVD and builds the TLS fixture + FFmpeg RGB oracle;
it never launches Flutter, Gradle, or an emulator. Normal mode validates strict
CodecInfo candidates on a virtual MediaCodec emulator, including CPU fallback.
--mode software-codec is a debug-only Java/JNI test, never physical hardware
acceptance. Wait for a coordinated Gradle window before builds.
"""
from contextlib import ExitStack, suppress
from pathlib import Path
import argparse
import base64
import hashlib
import importlib.util
import io
import json
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

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/android-h264-runtime'
AVD_HOME = OUT / 'avd'
PACKAGE = 'dev.lrdp.lrdp'
NDK = '27.0.12077973'


def properties(path):
    if not path.is_file():
        return {}
    return {k.strip(): v.strip() for line in path.read_text().splitlines()
            if '=' in line and not line.lstrip().startswith('#')
            for k, v in [line.split('=', 1)]}


def check(condition, reason):
    if not condition:
        raise AssertionError(reason)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def wait_for(predicate, reason, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError(reason)


class Runtime:
    def __init__(self, api, mode, software_component=None):
        local = properties(ROOT / 'android/local.properties')
        sdk = (os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
               or local.get('sdk.dir'))
        flutter_root = os.environ.get('FLUTTER_ROOT') or local.get('flutter.sdk')
        flutter = str(Path(flutter_root) / 'bin/flutter') if flutter_root else shutil.which('flutter')
        check(sdk and flutter, 'Configure SDK/Flutter environment or android/local.properties')
        self.sdk, self.flutter = Path(sdk).expanduser().resolve(), Path(flutter).expanduser().resolve()
        self.api, self.mode = api, mode
        check(software_component is None or mode == 'software-codec',
              '--software-component requires --mode software-codec')
        self.software_component = software_component
        self.device = None
        self.name = f'LRDP_H264_API{api}'
        self.avd_path = AVD_HOME / (self.name + '.avd')
        self.output = OUT / f'api{api}-{mode}'
        self.output.mkdir(parents=True, exist_ok=True)
        self.adb = [str(self.sdk / 'platform-tools/adb'), '-P', '5038', '-s', 'emulator-5556']
        # Reuse the already installed workspace JDK; no download and no Java27.
        candidates = [OUT / 'jdk21', ROOT / 'build/android-cpu-runtime/jdk21']
        jdk = os.environ.get('JAVA_HOME') or next((str(p) for p in candidates if p.is_dir()), '')
        self.java_home = Path(jdk)
        check((self.java_home / 'bin/java').is_file(), 'Set JAVA_HOME to JDK17..24')
        self.java = subprocess.check_output([str(self.java_home / 'bin/java'), '-version'],
                                            stderr=subprocess.STDOUT, text=True)
        major = int(re.search(r'version "(\d+)', self.java)[1])
        check(17 <= major <= 24, 'Gradle8.14 requires JDK17..24')
        check((self.sdk / 'ndk' / NDK).is_dir(), f'Install NDK {NDK}')
        self.env = dict(os.environ, JAVA_HOME=str(self.java_home),
                        ANDROID_HOME=str(self.sdk), ANDROID_SDK_ROOT=str(self.sdk),
                        ANDROID_AVD_HOME=str(AVD_HOME), ADB_SERVER_SOCKET='tcp:5038',
                        ANDROID_ADB_SERVER_PORT='5038',
                        LRDP_OPENSSL_ROOT=str(ROOT / 'build/deps/android-openssl'),
                        LRDP_FFMPEG_ROOT=str(ROOT / 'build/deps/ffmpeg/android'),
                        LRDP_BUILD_JOBS='3', CMAKE_BUILD_PARALLEL_LEVEL='3')
        self.env['PATH'] = str(self.java_home / 'bin') + ':' + str(self.flutter.parent) + ':' + self.env['PATH']
        self.env['GRADLE_OPTS'] = (f'-Dorg.gradle.java.home={self.java_home} '
                                   '-Dorg.gradle.workers.max=3 -Dorg.gradle.jvmargs=-Xmx2g')

    def android(self, *args, check=True, timeout=30):
        return subprocess.run(self.adb + list(args), check=check, timeout=timeout,
                              capture_output=True, text=True)

    def prepare(self):
        image = f'system-images/android-{self.api}/google_apis/x86_64/'
        check((self.sdk / image / 'package.xml').is_file(), f'Install SDK image {image}')
        AVD_HOME.mkdir(parents=True, exist_ok=True)
        config = self.avd_path / 'config.ini'
        if not config.is_file():
            run([str(self.sdk / 'cmdline-tools/latest/bin/avdmanager'), 'create', 'avd',
                 '--name', self.name, '--path', str(self.avd_path), '--package',
                 f'system-images;android-{self.api};google_apis;x86_64', '--device', 'pixel_2'],
                input='no\n', text=True, env=self.env, capture_output=True)
        values = properties(config)
        pointer = properties(AVD_HOME / (self.name + '.ini'))
        check(Path(pointer.get('path', '')).resolve() == self.avd_path.resolve()
              and pointer.get('target') == f'android-{self.api}'
              and values.get('abi.type') == 'x86_64'
              and values.get('image.sysdir.1') == image, 'Unexpected owned AVD configuration')
        values.update({'AvdId': self.name, 'avd.ini.displayname': self.name,
                       'hw.lcd.width': '720', 'hw.lcd.height': '1280',
                       'hw.lcd.density': '320', 'hw.ramSize': '2048',
                       'disk.dataPartition.size': '2G', 'showDeviceFrame': 'no',
                       'fastboot.forceColdBoot': 'yes'})
        config.write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
        return {'name': self.name, 'path': str(self.avd_path), 'config_sha256': sha(config),
                'api': self.api, 'abi': 'x86_64', 'adb_port': 5038, 'serial': 'emulator-5556'}

    def ensure_device(self, cleanup):
        state = self.android('get-state', check=False)
        if state.returncode != 0:
            for port in (5556, 5557):
                with socket.socket() as sock:
                    check(sock.connect_ex(('127.0.0.1', port)) != 0,
                          f'Port {port} occupied by unknown process')
            log = cleanup.enter_context((self.output / 'emulator.log').open('w'))
            emulator = subprocess.Popen([
                str(self.sdk / 'emulator/emulator'), '-avd', self.name, '-port', '5556',
                '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot',
                '-gpu', 'swiftshader_indirect', '-memory', '2048', '-no-metrics'],
                env=self.env, stdout=log, stderr=subprocess.STDOUT)
            cleanup.callback(stop, emulator)
            wait_for(lambda: self.android('get-state', check=False).stdout.strip() == 'device',
                     'Owned emulator did not attach', 120)
        check(self.name in self.android('emu', 'avd', 'name').stdout.splitlines(),
              'Refusing any other AVD on 5556')
        wait_for(lambda: self.android('shell', 'getprop', 'sys.boot_completed', check=False)
                 .stdout.strip() == '1', 'Owned emulator did not boot', 150)
        def prop(name):
            return self.android('shell', 'getprop', name).stdout.strip()
        check(prop('ro.build.version.sdk') == str(self.api), 'Wrong Android API')
        check(prop('ro.product.cpu.abi') == 'x86_64', 'Wrong ABI')
        check(self.android('shell', 'id', '-u').stdout.strip() == '2000', 'Do not use root')
        device = {'avd': self.name, 'api': self.api, 'abi': 'x86_64', 'shell_uid': 2000,
                  'adb_port': 5038, 'serial': 'emulator-5556',
                  'fingerprint': prop('ro.build.fingerprint'),
                  'display_dump': self.android('shell', 'dumpsys', 'display').stdout}
        self.device = device
        self.save('device.json', device)
        return device

    def save(self, name, value):
        (self.output / name).write_text(json.dumps(value, indent=2) + '\n')

    def fixture(self):
        spec = importlib.util.spec_from_file_location('h264_fixture_generator', ROOT / 'scripts/run_h264_test.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        fixture = self.output / 'h264_gfx_fixture'
        flags = shlex.split(subprocess.check_output([
            'pkg-config', '--cflags', '--libs', 'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
        command = ['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                   '-Wno-deprecated-declarations', str(ROOT / 'native/tests/h264_gfx_fixture.c'),
                   '-o', str(fixture), *flags]
        run(command, capture_output=True, text=True)
        packets, stream = module.generate(self.output)
        evidence = {'command': command, 'fixture_sha256': sha(fixture),
                    'source_sha256': sha(ROOT / 'native/tests/h264_gfx_fixture.c'), 'stream': stream}
        self.save('FIXTURE.json', evidence)
        return fixture, packets, evidence

    def apk_inputs(self):
        names = subprocess.check_output(['git', 'ls-files', '--cached', '--others',
                                         '--exclude-standard', '-z'], cwd=ROOT)
        digest = hashlib.sha256(b'LRDP-Android-H264-APK-v1\0LRDP_ANDROID_H264_TESTING=ON\0')
        for raw in sorted(set(names.split(b'\0')) - {b''}):
            name = raw.decode()
            if name.startswith(('lib/', 'assets/', 'android/', 'native/', 'packages/')) or name in (
                    'pubspec.yaml', 'pubspec.lock', 'integration_test/android_h264_test.dart'):
                path = ROOT / name
                if path.is_file():
                    digest.update(raw + b'\0' + path.read_bytes() + b'\0')
        digest.update(subprocess.check_output(['git', '-C', 'third_party/FreeRDP', 'rev-parse', 'HEAD'], cwd=ROOT))
        for folder in ('build/deps/android-openssl/x86_64/lib', 'build/deps/ffmpeg/android/x86_64/lib'):
            paths = sorted((ROOT / folder).glob('*.a'))
            check(paths, f'Dependencies not ready: {folder}')
            for path in paths:
                digest.update(path.name.encode() + sha(path).encode())
        digest.update(NDK.encode())
        return digest.hexdigest()

    def build(self, reuse):
        apk, metadata = OUT / 'h264-integration-x86_64.apk', OUT / 'APK_BUILD.json'
        inputs = self.apk_inputs()
        if reuse:
            info = json.loads(metadata.read_text())
            check(info['inputs'] == inputs and info['sha256'] == sha(apk), 'APK inputs changed; rebuild')
        else:
            defines = base64.b64encode(b'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false').decode()
            with (self.output / 'build.log').open('w') as log:
                run([str(ROOT / 'android/gradlew'), '--no-daemon', '--max-workers=3',
                     '-Dorg.gradle.jvmargs=-Xmx2g', ':app:assembleDebug',
                     '-Ptarget-platform=android-x64', '-Plrdp.h264Testing=1',
                     f'-Plrdp.ndkVersion={NDK}',
                     f'-Ptarget={ROOT / "integration_test/android_h264_test.dart"}',
                     f'-Pdart-defines={defines}'], cwd=ROOT / 'android', env=self.env,
                    stdout=log, stderr=subprocess.STDOUT)
            check(self.apk_inputs() == inputs, 'Sources changed during build')
            shutil.copy2(ROOT / 'build/app/outputs/apk/debug/app-debug.apk', apk)
            metadata.write_text(json.dumps({'inputs': inputs, 'sha256': sha(apk), 'ndk': NDK}, indent=2) + '\n')
        with (self.output / 'apk-check.log').open('w') as log:
            run([sys.executable, str(ROOT / 'scripts/check_android_apk.py'), str(apk),
                 '--abi', 'x86_64', '--integration'], env=self.env, stdout=log, stderr=subprocess.STDOUT)
        return apk

    def read_private(self, name):
        value = self.android('exec-out', 'run-as', PACKAGE, 'cat', 'files/' + name, check=False)
        try:
            return json.loads(value.stdout) if value.returncode == 0 else None
        except json.JSONDecodeError:
            return None

    def failure_evidence(self):
        self.save('failure-live.json', self.read_private('h264-live.json'))
        self.save('failure-device-result.json', self.read_private('h264-result.json'))
        pid = self.android('shell', 'pidof', PACKAGE, check=False).stdout.strip()
        if re.fullmatch(r'\d+', pid):
            log = self.android('logcat', '-d', '-v', 'threadtime', '--pid=' + pid, check=False)
            (self.output / 'failure-app-logcat.log').write_text(log.stdout + log.stderr)

    def write_private(self, name, data):
        check(re.fullmatch(r'h264-[a-z0-9.-]+', name), 'Invalid control filename')
        run(self.adb + ['shell', f"run-as {PACKAGE} sh -c 'cat > files/{name}'"],
            input=data.encode(), capture_output=True, timeout=25)

    def pixels(self, meta, indices):
        import numpy as np
        from PIL import Image
        data = subprocess.check_output(self.adb + ['exec-out', 'screencap', '-p'], timeout=20)
        image = Image.open(io.BytesIO(data)).convert('RGB')
        view = meta.get('view', [image.width, image.height])
        scale = image.width / view[0]
        # Older Android excludes its bottom navigation bar from Flutter's view,
        # while screencap includes it. Preserve the physical pixel scale in both
        # axes instead of stretching the app viewport to the full screen height.
        check(view[1] * scale <= image.height + 1, 'Flutter viewport exceeds screenshot')
        bounds = [round(v * scale) for v in meta['rect']]
        check(0 <= bounds[0] < bounds[2] <= image.width and
              0 <= bounds[1] < bounds[3] <= image.height, 'Texture bounds outside screenshot')
        x0, y0, x1, y1 = bounds
        # Two screen pixels exclude compositor edge filtering; all remaining RGB
        # pixels must match the corresponding FFmpeg-decoded image, not a count.
        actual = np.asarray(image)[y0 + 2:y1 - 2, x0 + 2:x1 - 2].astype(np.int16)
        reference = (self.output / 'reference.bgra').read_bytes()
        comparisons = []
        for index in indices:
            start = index * 3 * 320 * 240 * 4
            rgb = np.frombuffer(reference[start:start + 320 * 240 * 4], dtype=np.uint8).reshape(240, 320, 4)[:, :, [2, 1, 0]]
            expected = np.asarray(Image.fromarray(rgb).resize((x1 - x0, y1 - y0), Image.Resampling.NEAREST))[2:-2, 2:-2].astype(np.int16)
            maximum = int(np.abs(actual - expected).max())
            comparisons.append({'color_index': index, 'max_rgb_error_vs_ffmpeg': maximum,
                                'expected_center_rgb': expected[expected.shape[0] // 2, expected.shape[1] // 2].tolist()})
            if maximum <= 5:
                name = f'color-{index}' if meta['stage'] == 'color-stream' else 'silent-pixels'
                (self.output / (name + '.png')).write_bytes(data)
                self.save(name + '-pixels.json', {'color_index': index, 'rect': bounds,
                          'compared_rgb_pixels': int(actual.shape[0] * actual.shape[1]),
                          'max_rgb_error_vs_ffmpeg': maximum,
                          'actual_center_rgb': actual[actual.shape[0] // 2, actual.shape[1] // 2].tolist(),
                          'expected_center_rgb': expected[expected.shape[0] // 2, expected.shape[1] // 2].tolist()})
                return index
        # Preserve failures as well as successful colors, without weakening the oracle.
        (self.output / 'last-unmatched.png').write_bytes(data)
        self.save('last-unmatched-pixels.json', {'stage': meta['stage'], 'rect': bounds,
                  'compared_rgb_pixels': int(actual.shape[0] * actual.shape[1]),
                  'actual_center_rgb': actual[actual.shape[0] // 2, actual.shape[1] // 2].tolist(),
                  'comparisons': comparisons})
        return None

    def execute(self, apk, fixture, packets, cleanup):
        device = self.ensure_device(cleanup)
        temporary = cleanup.enter_context(tempfile.TemporaryDirectory(prefix='lrdp-android-h264-'))
        cert, key = Path(temporary) / 'cert.pem', Path(temporary) / 'key.pem'
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
             '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], capture_output=True)
        key.chmod(0o600)
        der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
        pin = ':'.join(f'{v:02x}' for v in hashlib.sha256(der).digest())
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.android('reverse', f'tcp:{port}', f'tcp:{port}')
        cleanup.callback(self.android, 'reverse', '--remove', f'tcp:{port}', check=False)
        self.android('shell', 'am', 'force-stop', PACKAGE)
        installed = self.android('install', '-r', '-t', str(apk), timeout=90, check=False)
        if 'INSTALL_FAILED_UPDATE_INCOMPATIBLE' in installed.stdout + installed.stderr:
            self.android('uninstall', PACKAGE)  # Only after ensure_device ownership.
            installed = self.android('install', '-r', '-t', str(apk), timeout=90)
        check(installed.returncode == 0 and 'Success' in installed.stdout, installed.stdout + installed.stderr)
        self.android('shell', 'pm', 'clear', PACKAGE)
        self.android('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'files')
        self.write_private('h264-fixture.json', json.dumps({
            'port': port, 'pin': pin, 'mode': self.mode,
            'software_component': self.software_component}))
        self.android('shell', 'wm', 'dismiss-keyguard')
        self.android('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
        self.android('shell', 'settings', 'put', 'system', 'user_rotation', '0')
        view = OUT / 'sdk-view'
        for relative in ('build-tools/36.0.0', 'platforms/android-36', 'platform-tools',
                         'emulator', 'cmdline-tools', 'ndk', 'cmake', 'licenses'):
            destination = view / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if not destination.exists() and (self.sdk / relative).exists():
                destination.symlink_to(self.sdk / relative, target_is_directory=True)
        drive_env = dict(self.env, ANDROID_HOME=str(view), ANDROID_SDK_ROOT=str(view))
        log = cleanup.enter_context((self.output / 'driver.log').open('w'))
        driver = subprocess.Popen([str(self.flutter), 'drive', '--no-pub', '--keep-app-running',
                                  '-d', 'emulator-5556', '--target', 'integration_test/android_h264_test.dart',
                                  '--driver', 'test_driver/android_runtime.dart',
                                  '--use-application-binary', str(apk)], cwd=ROOT, env=drive_env,
                                  stdout=log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, driver)
        cleanup.callback(self.android, 'shell', 'am', 'force-stop', PACKAGE, check=False)
        server, stages, colors = None, [], []
        def start_server(name):
            output = cleanup.enter_context((self.output / (name + '-server.log')).open('w'))
            process = subprocess.Popen([str(fixture), str(port), str(cert), str(key), *map(str, packets)],
                                       env=dict(self.env, WLOG_LEVEL='WARN',
                                                LRDP_H264_INITIAL_DELAY_MS='1000',
                                                LRDP_H264_FRAME_INTERVAL_MS='1000'),
                                       stdout=output, stderr=subprocess.STDOUT)
            cleanup.callback(stop, process)
            def listening():
                check(process.poll() is None, name + ' fixture exited')
                return any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                           for line in Path('/proc/net/tcp').read_text().splitlines()[1:])
            wait_for(listening, 'Fixture did not listen')
            return process
        deadline = time.monotonic() + 210
        while driver.poll() is None and time.monotonic() < deadline:
            meta = self.read_private('h264-stage.json')
            if meta and meta['stage'] not in stages:
                name = meta['stage']
                self.save(name + '.json', meta)
                if name == 'probe-ready':
                    server = start_server('probe')
                elif name == 'certificate-probed':
                    check(server and server.wait(timeout=5) == 1, 'Probe must reject unaccepted TLS')
                    server = start_server('accepted')
                elif name == 'color-stream':
                    def all_colors():
                        found = self.pixels(meta, [i for i in range(3) if i not in colors])
                        if found is not None:
                            colors.append(found)
                        return len(colors) == 3 and 'AVC420 final frame then silence' in (self.output / 'accepted-server.log').read_text()
                    try:
                        wait_for(all_colors, 'Missing real decoded color transitions', 15)
                    except AssertionError as error:
                        with suppress(Exception):
                            self.failure_evidence()
                        raise AssertionError(f'Color capture failed; observed={colors}; {error}') from error
                    finally:
                        self.save('color-stream-live.json', self.read_private('h264-live.json'))
                elif name == 'silent-pixels':
                    wait_for(lambda: self.pixels(meta, [2]) == 2, 'Wrong final silent AVC420 frame', 3)
                elif name == 'input-ack':
                    wait_for(lambda: 'Input A acknowledged' in (self.output / 'accepted-server.log').read_text(), 'No input acknowledgment', 3)
                    check(server.poll() is None, 'Fixture must stay connected until client stop')
                elif name == 'stopped':
                    check(server and server.wait(timeout=5) == 0, 'Fixture did not exit successfully after client stop')
                else:
                    raise AssertionError('Unknown stage ' + name)
                stages.append(name)
                self.write_private('h264-' + name + '.ack', '1')
                print('PASS Android H264 stage:', name, flush=True)
            result = self.read_private('h264-result.json')
            if result and not result['passed']:
                self.save('device-result.json', result)
                with suppress(Exception):
                    self.failure_evidence()
                raise AssertionError('Device test failed: ' + str(result.get('error')))
            time.sleep(.05)
        check(driver.poll() is not None, 'Flutter driver timed out')
        check(driver.wait(timeout=10) == 0, 'Flutter driver failed; see driver.log')
        result = self.read_private('h264-result.json')
        check(result and result['passed'], 'No successful device verdict')
        self.save('device-result.json', result)
        check(stages == ['probe-ready', 'certificate-probed', 'color-stream', 'silent-pixels',
                         'input-ack', 'stopped'] and colors == [0, 1, 2], 'Incomplete protocol/pixel coverage')
        with zipfile.ZipFile(apk) as archive:
            native_sha = hashlib.sha256(archive.read('lib/x86_64/liblrdp.so')).hexdigest()
        result.update(device=device, stages=stages, colors=colors, server_exit_code=server.returncode,
                      apk_sha256=sha(apk), native_library_sha256=native_sha,
                      apk_build=json.loads((OUT / 'APK_BUILD.json').read_text()),
                      runner_sha256=sha(Path(__file__).resolve()),
                      integration_test_sha256=sha(ROOT / 'integration_test/android_h264_test.dart'),
                      physical_device_tested=False, hardware_acceptance=False,
                      scope='Real Android virtual MediaCodec emulator private TLS/RDPGFX AVC420 9AU IDR/P, '
                            'native texture/system screenshot RGB oracle. Debug software-codec mode '
                            'exercises Java/JNI only; never evidence of hardware acceleration.')
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--api', type=int, default=36, choices=[26, 29, 30, 31, 32, 33, 34, 35, 36])
    parser.add_argument('--mode', choices=['normal', 'software-codec'], default='normal')
    parser.add_argument('--software-component', help='Exact strict software candidate name; debug software-codec mode only')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--reuse-apk', action='store_true')
    args = parser.parse_args()
    if args.software_component and args.mode != 'software-codec':
        parser.error('--software-component requires --mode software-codec')
    runtime = Runtime(args.api, args.mode, args.software_component)
    verdict = {'passed': False, 'device_tested': False, 'hardware_acceptance': False}
    try:
        verdict.update(avd=runtime.prepare(), java=runtime.java)
        fixture, packets, evidence = runtime.fixture()
        verdict['fixture'] = evidence
        if args.prepare_only:
            runtime.save('PREPARED.json', dict(verdict, prepared=True))
            print('Prepared isolated H264 AVD + real 9AU oracle:', runtime.avd_path)
            return 0
        apk = runtime.build(args.reuse_apk)
        if args.build_only:
            print(apk)
            return 0
        with ExitStack() as cleanup:
            verdict.update(runtime.execute(apk, fixture, packets, cleanup), device_tested=True)
    except Exception as error:
        verdict['error'] = f'{type(error).__name__}: {error}'
        if isinstance(error, subprocess.CalledProcessError):
            stderr = error.stderr
            verdict['command_stderr'] = stderr.decode(errors='replace') if isinstance(stderr, bytes) else stderr
    if runtime.device is not None:
        verdict.update(device_tested=True, device=runtime.device)
    runtime.save('VERDICT.json', verdict)
    print(json.dumps(verdict, indent=2))
    return 0 if verdict['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
