#!/usr/bin/env python3
"""Build and run the Android integration APK on the private LRDP emulator.

Uses a private LRDP AVD, isolated RDP file/desktop fixtures, a transparent
loopback fault proxy, adb reverse and a private X server. Never captures or controls the user's desktop/phone.
The integration APK is kept in build/android-runtime, not distributions.
"""
from contextlib import ExitStack
from pathlib import Path
import argparse
import base64
import ctypes as c
import hashlib
import json
import os
import re
import select
import shlex
import shutil
import socket
import sys
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', default='emulator-5556')
parser.add_argument('--adb-port', type=int, default=5038)
parser.add_argument('--avd-name', default='LRDP_API36_16k')
args = parser.parse_args()
sdk = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'Android/Sdk')))
adb = [str(sdk / 'platform-tools/adb'), '-P', str(args.adb_port), '-s', args.serial]
output = root / 'build/android-runtime'
output.mkdir(parents=True, exist_ok=True)
(output / 'VERDICT.json').unlink(missing_ok=True)
package = 'dev.lrdp.lrdp'


def command(parts, **kwargs):
    return subprocess.run(parts, check=True, **kwargs)


def android(*parts, check=True):
    result = subprocess.run([*adb, *parts], capture_output=True, text=True, timeout=30)
    if check and result.returncode:
        raise RuntimeError(f'Android command failed: {parts}: {result.stderr.strip()} {result.stdout.strip()}')
    return result


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def listening(process, port):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and process.poll() is None:
        for line in Path('/proc/net/tcp').read_text().splitlines()[1:]:
            fields = line.split()
            if fields[1] == f'0100007F:{port:04X}' and fields[3] == '0A':
                return
        time.sleep(.1)
    raise RuntimeError(f'Fixture port {port} did not listen')


class XInput:
    """Observe actual mouse events forwarded to the private server desktop."""
    def __init__(self, display):
        self.x = c.CDLL('libX11.so.6')
        self.x.XOpenDisplay.argtypes = [c.c_char_p]
        self.x.XOpenDisplay.restype = c.c_void_p
        self.x.XDefaultRootWindow.argtypes = [c.c_void_p]
        self.x.XDefaultRootWindow.restype = c.c_ulong
        self.x.XSelectInput.argtypes = [c.c_void_p, c.c_ulong, c.c_long]
        self.x.XSync.argtypes = [c.c_void_p, c.c_int]
        self.x.XPending.argtypes = [c.c_void_p]
        self.x.XNextEvent.argtypes = [c.c_void_p, c.c_void_p]
        self.x.XCloseDisplay.argtypes = [c.c_void_p]
        self.display = self.x.XOpenDisplay(display.encode())
        if not self.display:
            raise RuntimeError('Could not observe the private X display')
        self.window = self.x.XDefaultRootWindow(self.display)
        self.x.XSelectInput(self.display, self.window, (1 << 2) | (1 << 3) | (1 << 6))
        self.x.XSync(self.display, 0)

    def events(self):
        self.x.XSync(self.display, 0)
        events = []
        while self.x.XPending(self.display):
            event = (c.c_long * 24)()
            self.x.XNextEvent(self.display, event)
            events.append(c.cast(event, c.POINTER(c.c_int))[0])
        return events

    def close(self):
        self.x.XCloseDisplay(self.display)


def hierarchy():
    deadline = time.monotonic() + 30
    last = ''
    while time.monotonic() < deadline:
        dumped = android('shell', 'uiautomator', 'dump', '/sdcard/lrdp-window.xml', check=False)
        last = dumped.stdout + dumped.stderr
        # Android can return exit 0 with "null root node" during a native
        # activity transition. Do not parse that response or reuse an old dump.
        if dumped.returncode == 0 and 'dumped to:' in dumped.stdout:
            result = android('exec-out', 'cat', '/sdcard/lrdp-window.xml', check=False)
            try:
                tree = ET.fromstring(result.stdout)
                (output / 'native-hierarchy.xml').write_text(result.stdout)
                return tree
            except ET.ParseError:
                last += '\n' + result.stdout + result.stderr
        time.sleep(.3)
    (output / 'hierarchy-last-error.txt').write_text(last)
    (output / 'hierarchy-window-state.txt').write_text(android('shell','dumpsys','window',check=False).stdout)
    screenshot('android-hierarchy-failure')
    raise RuntimeError('Android native hierarchy did not become ready: ' + last[:500])


def tap_node(predicate, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for node in hierarchy().iter('node'):
            if predicate(node.attrib):
                bounds = list(map(int, re.findall(r'\d+', node.attrib.get('bounds', ''))))
                if len(bounds) == 4:
                    android('shell', 'input', 'tap', str((bounds[0] + bounds[2]) // 2), str((bounds[1] + bounds[3]) // 2))
                    return
        time.sleep(.5)
    raise RuntimeError('Expected Android system picker control was not found')


def screenshot(stage):
    result = subprocess.run([*adb, 'exec-out', 'screencap', '-p'], check=True, capture_output=True, timeout=30)
    assert result.stdout.startswith(b'\x89PNG\r\n\x1a\n')
    (output / f'{stage}.png').write_bytes(result.stdout)


def reset_test_activity():
    focus = next((line for line in android('shell', 'dumpsys', 'window', check=False).stdout.splitlines()
                  if 'mCurrentFocus=' in line), '')
    if any(name in focus for name in ('documentsui.picker.PickActivity', 'ChooserActivity', 'ResolverActivity')):
        android('shell', 'input', 'keyevent', 'KEYCODE_BACK', check=False)
    android('shell', 'am', 'force-stop', package, check=False)


def handle_stage(stage, observer, fault):
    if stage == 'android-workspace':
        focus = next((line for line in android('shell', 'dumpsys', 'window').stdout.splitlines()
                      if 'mCurrentFocus=' in line), '')
        if package not in focus:
            screenshot('android-unexpected-focus')
            raise RuntimeError(f'The Android OS has not given the app window focus: {focus.strip()}')
    if stage == 'android-cursor-xor':
        proof=android('exec-out','run-as',package,'cat','files/lrdp-integration-cursor-render.json')
        data=json.loads(proof.stdout)
        assert data['pixel']==[231,210,215,255]
        (output/'cursor-render.json').write_text(json.dumps(data,indent=2)+'\n')
    elif stage == 'android-touch-input':
        observer.events()
        from PIL import Image
        import io
        # wm size describes the natural orientation; injected coordinates use
        # the currently rotated display shown by the Android compositor.
        pixels = subprocess.check_output([*adb, 'exec-out', 'screencap', '-p'], timeout=30)
        width, height = Image.open(io.BytesIO(pixels)).size
        android('shell', 'input', 'swipe', str(width // 2), str(height // 2),
                str(width // 2 + width // 10), str(height // 2 + height // 40), '400')
        android('shell', 'input', 'tap', str(width // 2), str(height // 2))
        events = set()
        deadline = time.monotonic() + 10
        while not {4, 5}.issubset(events) and time.monotonic() < deadline:
            events.update(observer.events())
            time.sleep(.1)
        assert {4, 5, 6}.issubset(events), f'Android touch did not reach server X11: {events}'
    elif stage == 'android-background-resume':
        android('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        time.sleep(1)
        android('shell', 'am', 'start', '--activity-reorder-to-front', '--activity-single-top',
                '-n', f'{package}/.MainActivity')
        time.sleep(1)
    elif stage == 'android-background-loss':
        android('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        time.sleep(1)
        before = fault('drop')['connections']
        time.sleep(4)
        after = fault('stats')['connections']
        assert after == before, f'Background reconnect consumed handshakes: {before} -> {after}'
        (output / 'background-fault.json').write_text(json.dumps({'before': before, 'after': after}))
        return
    elif stage in ('android-network-resume', 'android-certificate-return'):
        android('shell', 'am', 'start', '--activity-reorder-to-front', '--activity-single-top',
                '-n', f'{package}/.MainActivity')
        time.sleep(1)
        return
    elif stage == 'android-certificate-hold':
        fault('hold')
        fault('rotate')
        return
    elif stage == 'android-certificate-inflight':
        android('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        time.sleep(1)
        fault('release')
        return
    elif stage == 'android-certificate-deferred':
        before = fault('stats')['connections']
        time.sleep(3)
        after = fault('stats')['connections']
        assert before == after, 'Certificate rejection retried while backgrounded'
        (output / 'certificate-fault.json').write_text(json.dumps({'before': before, 'after': after}))
        return
    elif stage in ('android-rotate-landscape', 'android-editor-landscape'):
        android('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
        android('shell', 'settings', 'put', 'system', 'user_rotation', '1')
        time.sleep(1)
    elif stage in ('android-rotate-portrait', 'android-editor-portrait'):
        android('shell', 'settings', 'put', 'system', 'user_rotation', '0')
        time.sleep(1)
    elif stage == 'android-document-picker':
        # Real DocumentsUI, with a file pushed only into this disposable AVD.
        tree = hierarchy()
        assert any('documentsui' in n.get('package', '') for n in tree.iter('node'))
        screenshot(stage)
        tap_node(lambda n: n.get('content-desc') in ('Show roots', '显示根目录', '打开导航抽屉'))
        tap_node(lambda n: n.get('text') in ('Downloads', '下载'))
        tap_node(lambda n: n.get('text') == '手机选中的中文文件.txt')
        return
    elif stage == 'android-share-sheet':
        target = android('exec-out', 'run-as', package, 'cat', 'files/lrdp-integration-share-target.json', check=False)
        (output / 'share-target.json').write_text(target.stdout)
        tap_node(lambda n: n.get('content-desc') == '保存或分享' and n.get('enabled') == 'true')
        deadline = time.monotonic() + 20
        focus = ''
        while time.monotonic() < deadline:
            focus = next((line for line in android('shell', 'dumpsys', 'window').stdout.splitlines()
                          if 'mCurrentFocus=' in line), '')
            if any(name in focus for name in ('ChooserActivity', 'ResolverActivity')):
                break
            time.sleep(.3)
        # ChooserActivity can expose no accessibility root on API 36. Its
        # focused native window is the launch assertion; no chooser item is
        # being selected here. Keep the actual native tap above and capture
        # focus/screenshot before asserting, including the failure case.
        (output / 'share-focus.txt').write_text(focus + '\n')
        pointer = android('exec-out', 'run-as', package, 'cat', 'files/lrdp-integration-pointer.json', check=False)
        (output / 'share-pointer.json').write_text(pointer.stdout)
        screenshot('android-share-attempt')
        assert any(name in focus for name in ('ChooserActivity', 'ResolverActivity')), focus
        screenshot(stage)
        android('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        return
    screenshot(stage)


if not args.avd_name.startswith('LRDP_') or not args.serial.startswith('emulator-'):
    raise SystemExit('This harness controls only an explicitly selected private LRDP emulator')
openssl = Path(os.environ.get('LRDP_OPENSSL_ROOT', str(root / 'build/deps/android-openssl')))
ffmpeg = Path(os.environ.get('LRDP_FFMPEG_ROOT', str(root / 'build/deps/ffmpeg/android')))
if not (openssl / 'x86_64/lib/libssl.a').exists():
    raise SystemExit('Build OpenSSL for x86_64 with scripts/build_android_openssl.sh first')
if not (ffmpeg / 'x86_64/lib/libavcodec.a').exists():
    raise SystemExit('Build FFmpeg with scripts/build_ffmpeg.sh android-x64 first')
environment = dict(os.environ, JAVA_HOME=os.environ.get('LRDP_JAVA_HOME', '/usr/lib/jvm/java-17-openjdk'),
                   ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk),
                   LRDP_OPENSSL_ROOT=str(openssl), CMAKE_BUILD_PARALLEL_LEVEL='3',
                   LRDP_FFMPEG_ROOT=str(ffmpeg),
                   LRDP_BUILD_JOBS='3',
                   ADB_SERVER_SOCKET=f'tcp:{args.adb_port}', ANDROID_ADB_SERVER_PORT=str(args.adb_port),
                   FLUTTER_TEST_OUTPUTS_DIR=str(output))
environment['PATH'] = environment['JAVA_HOME'] + '/bin:/opt/flutter/bin:' + environment['PATH']
# Flutter's prebuilt-APK launcher can select an incomplete SDK preview directory
# over the stable version. Expose only this project's toolchain to that launcher
# without deleting or changing anything in the user's SDK installation.
sdk_view = root / 'build/android-sdk-view'
for relative in ('build-tools/36.0.0', 'platforms/android-36', 'platform-tools',
                 'emulator', 'cmdline-tools', 'ndk', 'cmake', 'licenses'):
    source = sdk / relative
    destination = sdk_view / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.exists() and not destination.exists():
        destination.symlink_to(source, target_is_directory=True)
drive_environment = dict(environment, ANDROID_HOME=str(sdk_view), ANDROID_SDK_ROOT=str(sdk_view))

with tempfile.TemporaryDirectory(prefix='lrdp-android-test-') as temp, ExitStack() as cleanup:
    private = Path(temp)
    # Reserve both loopback ports while the cold integration APK is building.
    sockets = [cleanup.enter_context(socket.socket()) for _ in range(5)]
    for sock in sockets:
        sock.bind(('127.0.0.1', 0))
    file_port, ui_port, alternate_port, cursor_port, paste_port = [sock.getsockname()[1] for sock in sockets]
    cert, key = private / 'cert.pem', private / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
                    '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
    pin = ':'.join(f'{b:02x}' for b in hashlib.sha256(der).digest())
    # This legacy suite samples Dart images. Native Surface pixels and default-mode gestures have separate OS screenshot suites.
    definitions = {'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE': 'false', 'LRDP_DISABLE_TEXTURES': 'true'}
    encoded = ','.join(base64.b64encode(f'{key}={value}'.encode()).decode() for key, value in definitions.items())
    build_log = cleanup.enter_context((output / 'build.log').open('w'))
    print('Building isolated Android x86_64 integration APK', flush=True)
    command([str(root / 'android/gradlew'), '--no-daemon', '--max-workers=3', '-Dorg.gradle.jvmargs=-Xmx2g',
             ':app:assembleDebug', '-Ptarget-platform=android-x64',
             f'-Ptarget={root / "integration_test/android_runtime_test.dart"}', f'-Pdart-defines={encoded}'],
            cwd=root / 'android', env=environment, stdout=build_log, stderr=subprocess.STDOUT)
    apk = output / 'integration-x86_64.apk'
    shutil.copy2(root / 'build/app/outputs/apk/debug/app-debug.apk', apk)
    command(['python3', str(root / 'scripts/check_android_apk.py'), str(apk), '--abi', 'x86_64',
             '--integration', '--sdk-root', str(sdk)], env=environment)
    print('Waiting for the private Android device to finish booting', flush=True)
    boot_deadline = time.monotonic() + 600
    while time.monotonic() < boot_deadline:
        if android('shell', 'getprop', 'sys.boot_completed', check=False).stdout.strip() == '1':
            break
        time.sleep(1)
    else:
        raise RuntimeError('Private Android device did not finish booting; client runtime tests have not run')
    if args.avd_name not in android('emu', 'avd', 'name').stdout.splitlines():
        raise RuntimeError('The selected emulator is not the private LRDP AVD')
    page_size = int(android('shell', 'getconf', 'PAGE_SIZE').stdout.strip())
    assert page_size == 16384, page_size
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
    for name in ('rdp_fixture', 'cursor_fixture', 'paste_fixture'):
        command(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
             str(root / f'native/tests/{name}.c'), '-o', str(output / name), *flags])
    display = next(n for n in range(101, 201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
    server_env = dict(environment, DISPLAY=f':{display}', XDG_CONFIG_HOME=str(private / 'config'))
    xlog = cleanup.enter_context((output / 'display.log').open('w'))
    desktop = subprocess.Popen(['Xvnc', server_env['DISPLAY'], '-geometry', '1280x800', '-depth', '24',
        '-SecurityTypes', 'None', '-noreset', '-rfbport', '-1', '-rfbunixpath', str(private / 'vnc.sock'),
        '-rfbunixmode', '0600', '-nolisten', 'tcp'], env=server_env, stdout=xlog, stderr=subprocess.STDOUT)
    cleanup.callback(stop, desktop)
    deadline = time.monotonic() + 20
    while not Path(f'/tmp/.X11-unix/X{display}').exists() and time.monotonic() < deadline:
        assert desktop.poll() is None, 'Private X server failed'
        time.sleep(.1)
    observer = XInput(server_env['DISPLAY'])
    cleanup.callback(observer.close)
    command(['xsetroot', '-solid', '#182d28'], env=server_env)
    for sock in sockets:
        sock.close()
    flog = cleanup.enter_context((output / 'file-server.log').open('w'))
    fixture = subprocess.Popen([str(output / 'rdp_fixture'), str(file_port), str(cert), str(key), '300000'],
                               env=server_env, stdout=flog, stderr=subprocess.STDOUT)
    cleanup.callback(stop, fixture)
    slog = cleanup.enter_context((output / 'ui-server.log').open('w'))
    shadow = subprocess.Popen(['freerdp-shadow-cli3', '/bind-address:127.0.0.1', f'/port:{ui_port}',
        '/sec:tls', '-auth', '+may-view', '+may-interact', '+gfx-avc420', '-gfx-avc444', '/log-level:WARN'],
        env=server_env, stdout=slog, stderr=subprocess.STDOUT)
    cleanup.callback(stop, shadow)
    alternate_log = cleanup.enter_context((output / 'alternate-server.log').open('w'))
    alternate = subprocess.Popen(['freerdp-shadow-cli3', '/bind-address:127.0.0.1', f'/port:{alternate_port}',
        '/sec:tls', '-auth', '+may-view', '+may-interact', '+gfx-avc420', '-gfx-avc444', '/log-level:WARN'],
        env=dict(server_env, XDG_CONFIG_HOME=str(private / 'alternate-config')),
        stdout=alternate_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, alternate)
    cursor_log = cleanup.enter_context((output / 'cursor-server.log').open('w'))
    cursor_server = subprocess.Popen([str(output / 'cursor_fixture'),str(cursor_port),str(cert),str(key)],
        env=server_env,stdout=cursor_log,stderr=subprocess.STDOUT)
    cleanup.callback(stop,cursor_server)
    paste_log = cleanup.enter_context((output / 'paste-server.log').open('w'))
    paste_server = subprocess.Popen([str(output / 'paste_fixture'), str(paste_port), str(cert), str(key), 'normal', '300000', '120000'],
        env=server_env, stdout=paste_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, paste_server)
    for process, port in ((fixture, file_port), (shadow, ui_port), (alternate, alternate_port), (cursor_server, cursor_port), (paste_server, paste_port)):
        listening(process, port)
    fault_path = str(private / 'fault-control.sock')
    proxy_log = cleanup.enter_context((output / 'proxy.log').open('w'))
    proxy = subprocess.Popen([sys.executable, str(root / 'scripts/recovery_proxy.py'),
        '--port', str(ui_port), '--alternate-port', str(alternate_port), '--control', fault_path],
        stdout=subprocess.PIPE, stderr=proxy_log, text=True)
    cleanup.callback(stop, proxy)
    assert select.select([proxy.stdout], [], [], 10)[0], 'Android proxy startup timed out'
    response = proxy.stdout.readline()
    assert response, 'Android fault proxy failed'
    proxy_port = json.loads(response)['port']
    def fault(action):
        with socket.socket(socket.AF_UNIX) as stream:
            stream.settimeout(10)
            stream.connect(fault_path)
            stream.sendall((action + '\n').encode())
            data = b''
            while b'\n' not in data:
                part = stream.recv(4096)
                if not part: raise RuntimeError('Fault controller closed early')
                data += part
            return json.loads(data)
    for port in (file_port, proxy_port, cursor_port, paste_port):
        android('reverse', f'tcp:{port}', f'tcp:{port}')
        cleanup.callback(lambda p=port: android('reverse', '--remove', f'tcp:{p}', check=False))
    for setting in ('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale'):
        android('shell', 'settings', 'put', 'global', setting, '0')
    android('shell', 'settings', 'put', 'secure', 'show_ime_with_hard_keyboard', '1')
    android('shell', 'wm', 'size', '720x1600')
    android('shell', 'wm', 'density', '280')
    android('shell', 'wm', 'dismiss-keyguard')
    android('shell', 'svc', 'power', 'stayon', 'true')
    android('shell', 'mkdir', '-p', '/sdcard/Download')
    upload = private / '手机选中的中文文件.txt'
    upload.write_text('来自 Android 系统文件选择器的中文内容\n')
    android('push', str(upload), '/sdcard/Download/手机选中的中文文件.txt')
    android('shell', 'am', 'broadcast', '-a', 'android.intent.action.MEDIA_SCANNER_SCAN_FILE',
            '-d', 'file:///sdcard/Download/手机选中的中文文件.txt')
    android('shell', 'run-as', package, 'rm', '-f', 'files/lrdp-integration-stage', check=False)
    reset_test_activity()
    cleanup.callback(reset_test_activity)
    log = cleanup.enter_context((output / 'driver.log').open('w'))
    driver = subprocess.Popen(['flutter', 'drive', '--no-pub', '-d', args.serial,
        '--target', 'integration_test/android_runtime_test.dart', '--driver', 'test_driver/android_runtime.dart',
        '--use-application-binary', str(apk)], cwd=root, env=drive_environment, stdout=log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, driver)
    stages = set()
    app_pids = set()
    deadline = time.monotonic() + 600
    print('Running actual Android UI and protocol checks', flush=True)
    while driver.poll() is None and time.monotonic() < deadline:
        pids = android('shell', 'pidof', package, check=False).stdout.split()
        app_pids.update(pid for pid in pids if pid.isdigit())
        result = android('exec-out', 'run-as', package, 'cat', 'files/lrdp-integration-stage', check=False)
        stage = result.stdout.strip()
        if re.fullmatch(r'android-[a-z-]+', stage) and stage not in stages:
            print(f'Android stage: {stage}', flush=True)
            if stage == 'android-config':
                configuration = json.dumps({'filePort': file_port, 'uiPort': proxy_port, 'cursorPort': cursor_port, 'pastePort': paste_port, 'filePin': pin})
                command([*adb, 'shell', 'run-as', package, 'tee', 'files/lrdp-integration-config.tmp'],
                        input=configuration, text=True, capture_output=True, timeout=30)
                android('shell', 'run-as', package, 'mv', 'files/lrdp-integration-config.tmp',
                        'files/lrdp-integration-config.json')
            else:
                handle_stage(stage, observer, fault)
            android('shell', 'run-as', package, 'touch', f'files/lrdp-integration-captures/{stage}.ack')
            stages.add(stage)
        time.sleep(.3)
    assert driver.poll() == 0, f'Android driver failed or timed out; see {output / "driver.log"}'
    assert fixture.wait(timeout=10) == 0, (output / 'file-server.log').read_text()[-4000:]
    assert paste_server.wait(timeout=10) == 0, (output / 'paste-server.log').read_text()[-4000:]
    assert cursor_server.wait(timeout=10) == 0, (output / 'cursor-server.log').read_text()[-4000:]
    expected_stages = {'android-editor-landscape', 'android-editor-portrait', 'android-cursor-xor', 'android-paste', 'android-avc', 'android-workspace', 'android-editor-ime', 'android-certificate', 'android-touch-input',
                       'android-background-resume', 'android-keyboard', 'android-landscape-keyboard',
                       'android-document-picker', 'android-files', 'android-share-sheet', 'android-background-loss',
                       'android-network-resume', 'android-network-recovered', 'android-certificate-inflight',
                       'android-certificate-deferred', 'android-certificate-return', 'android-certificate-changed'}
    assert expected_stages.issubset(stages), stages
    assert app_pids, 'No Android application process was observed'
    assert json.loads((output / 'cursor-render.json').read_text())['nativeAbi'] == 5
    android_log = '\n'.join(android('logcat', '-d', f'--pid={pid}', '-s',
                                    'AndroidRuntime:E', 'libc:F', 'flutter:E').stdout for pid in sorted(app_pids))
    (output / 'android-errors.log').write_text(android_log)
    assert 'FATAL EXCEPTION' not in android_log and 'Fatal signal' not in android_log
    report = {'sdk': android('shell', 'getprop', 'ro.build.version.sdk').stdout.strip(),
              'abi': android('shell', 'getprop', 'ro.product.cpu.abi').stdout.strip(),
              'page_size': page_size, 'emulator': args.avd_name, 'physical_device': False,
              'stages': sorted(stages), 'result': 'passed',
              'cursor': 'real TLS alpha, AND/XOR, cached/null/default, server position, 384x384 with Dart image decode',
              'native_abi': 5,
              'rendering': 'CPU compatibility via LRDP_DISABLE_TEXTURES=true; default native Surface and gestures verified separately',
              'avc_decode': 'native successful AVC surface decode and actual phone RDP image',
              'clipboard_paste': 'phone composer, CLIPRDR ACK, Ctrl+V and exact Chinese UTF-16 response',
              'cursor_renderer': json.loads((output/'cursor-render.json').read_text()),
              'fault_injection': {'background_loss': json.loads((output / 'background-fault.json').read_text()),
                                  'certificate_deferred': json.loads((output / 'certificate-fault.json').read_text()),
                                  'transport': 'real end-to-end TLS through private TCP proxy; adb reverse',
                                  'physical_network_switch': False}}
    (output / 'VERDICT.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: Android 16 KiB runtime, Keystore, TLS, Unicode, 1 MiB files and native phone interactions', flush=True)
