#!/usr/bin/env python3
"""Run the Windows PE bridge under Wine against private loopback RDP fixtures.

This verifies the cross-compiled core, not the Flutter Windows runner or a
physical Windows installation. Uses only its own Wine prefix and X display.
"""
from contextlib import ExitStack
from pathlib import Path
import ctypes as c
import argparse
import hashlib
import json
import os
import shlex
import shutil
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sspi-provider', choices=('system', 'winpr'), default='system',
                    help='Authentication provider under Wine; real Windows defaults to system SSPI')
args = parser.parse_args()
build = root / 'build/windows-x64'
runtime = root / 'build/windows-runtime'
output = runtime / args.sspi_provider
output.mkdir(parents=True, exist_ok=True)
(output / 'VERDICT.json').unlink(missing_ok=True)
(output / 'RESULT.json').unlink(missing_ok=True)
for tool in ('wine', 'wineboot', 'wineserver', 'Xvnc', 'xsetroot', 'freerdp-shadow-cli3'):
    if not shutil.which(tool):
        raise SystemExit(f'Missing Windows core test dependency: {tool}')
for name in ('lrdp.dll', 'lrdp_bridge_test.exe', 'lrdp_windows_protocol.exe'):
    if not (build / name).is_file():
        raise SystemExit('Run scripts/build_windows_core.sh first: missing ' + name)
with (build / 'lrdp.dll').open('rb') as binary:
    core_sha256 = hashlib.file_digest(binary, 'sha256').hexdigest()


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def windows_path(path):
    # This private prefix has Wine's standard Z: mapping to the host filesystem.
    return 'Z:' + str(Path(path).resolve()).replace('/', '\\')


def listening(process, port):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and process.poll() is None:
        for line in Path('/proc/net/tcp').read_text().splitlines()[1:]:
            fields = line.split()
            if fields[1] == f'0100007F:{port:04X}' and fields[3] == '0A':
                return
        time.sleep(.1)
    raise RuntimeError(f'Private fixture did not listen on {port}')


class InputWindow:
    class KeyEvent(c.Structure):
        _fields_ = [('type', c.c_int), ('serial', c.c_ulong), ('send_event', c.c_int),
            ('display', c.c_void_p), ('window', c.c_ulong), ('root', c.c_ulong),
            ('subwindow', c.c_ulong), ('time', c.c_ulong), ('x', c.c_int), ('y', c.c_int),
            ('x_root', c.c_int), ('y_root', c.c_int), ('state', c.c_uint),
            ('code', c.c_uint), ('same_screen', c.c_int)]

    def __init__(self, display):
        self.x = c.CDLL('libX11.so.6')
        self.x.XOpenDisplay.argtypes = [c.c_char_p]
        self.x.XOpenDisplay.restype = c.c_void_p
        self.x.XDefaultRootWindow.argtypes = [c.c_void_p]
        self.x.XDefaultRootWindow.restype = c.c_ulong
        self.x.XCreateSimpleWindow.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_int,
            c.c_uint, c.c_uint, c.c_uint, c.c_ulong, c.c_ulong]
        self.x.XCreateSimpleWindow.restype = c.c_ulong
        self.x.XSelectInput.argtypes = [c.c_void_p, c.c_ulong, c.c_long]
        self.x.XMapWindow.argtypes = [c.c_void_p, c.c_ulong]
        self.x.XSetInputFocus.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_ulong]
        self.x.XSync.argtypes = [c.c_void_p, c.c_int]
        self.x.XPending.argtypes = [c.c_void_p]
        self.x.XNextEvent.argtypes = [c.c_void_p, c.c_void_p]
        self.x.XCloseDisplay.argtypes = [c.c_void_p]
        self.x.XKeysymToKeycode.argtypes = [c.c_void_p, c.c_ulong]
        self.x.XKeysymToKeycode.restype = c.c_ubyte
        self.display = self.x.XOpenDisplay(display.encode())
        assert self.display, 'Private X connection failed'
        self.a_keycode = self.x.XKeysymToKeycode(self.display, 0x61)
        self.keys_down, self.keys_up = set(), set()
        self.buttons_down, self.buttons_up = set(), set()
        root_window = self.x.XDefaultRootWindow(self.display)
        self.window = self.x.XCreateSimpleWindow(self.display, root_window, 40, 40,
                                               400, 300, 0, 0, 0x182d28)
        self.x.XSelectInput(self.display, self.window, 1 | 2 | 4 | 8 | 64)
        self.x.XMapWindow(self.display, self.window)
        self.x.XSetInputFocus(self.display, self.window, 1, 0)
        self.x.XSync(self.display, 0)

    def events(self):
        self.x.XSync(self.display, 0)
        events = []
        while self.x.XPending(self.display):
            event = (c.c_long * 24)()
            self.x.XNextEvent(self.display, event)
            kind = c.cast(event, c.POINTER(c.c_int))[0]
            events.append(kind)
            record = c.cast(event, c.POINTER(self.KeyEvent)).contents
            if kind == 2:
                self.keys_down.add(record.code)
            elif kind == 3:
                self.keys_up.add(record.code)
            elif kind == 4:
                self.buttons_down.add(record.code)
            elif kind == 5:
                self.buttons_up.add(record.code)
        return events

    @property
    def complete(self):
        return (self.a_keycode in self.keys_down and self.a_keycode in self.keys_up
                and 1 in self.buttons_down and 1 in self.buttons_up)

    def close(self):
        self.x.XCloseDisplay(self.display)


with tempfile.TemporaryDirectory(prefix='lrdp-windows-') as temp, ExitStack() as cleanup:
    private = Path(temp)
    display = next(n for n in range(101, 201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
    # Never initialize or stop the user's default Wine prefix.
    environment = dict(os.environ, DISPLAY=f':{display}', WINEPREFIX=str(runtime / 'wineprefix'),
        WINEARCH='win64', WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=',
        WINPR_NATIVE_SSPI='0' if args.sspi_provider == 'winpr' else '1',
        XDG_CONFIG_HOME=str(private / 'config'), XDG_DATA_HOME=str(private / 'data'))
    desktop_log = cleanup.enter_context((output / 'display.log').open('w'))
    desktop = subprocess.Popen(['Xvnc', environment['DISPLAY'], '-geometry', '1280x800', '-depth', '24',
        '-SecurityTypes', 'None', '-noreset', '-rfbport', '-1', '-rfbunixpath', str(private / 'vnc.sock'),
        '-rfbunixmode', '0600', '-nolisten', 'tcp'], env=environment,
        stdout=desktop_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, desktop)
    deadline = time.monotonic() + 20
    while not Path(f'/tmp/.X11-unix/X{display}').exists() and time.monotonic() < deadline:
        assert desktop.poll() is None, 'Private X server failed'
        time.sleep(.1)
    cleanup.callback(subprocess.run, ['wineserver', '-k'], env=environment,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    wine_log = cleanup.enter_context((output / 'wineboot.log').open('w'))
    print(f'Initializing private 64-bit Wine prefix; SSPI provider={args.sspi_provider}', flush=True)
    if not (runtime / 'wineprefix/.update-timestamp').exists():
        try:
            subprocess.run(['wineboot', '--init'], env=environment, stdout=wine_log,
                           stderr=subprocess.STDOUT, timeout=120, check=True)
        except subprocess.TimeoutExpired:
            # A first boot can finish registry setup while its boot service
            # remains pending. Restart only this prefix and prove readiness by
            # executing a real Windows process; files alone are not a pass.
            subprocess.run(['wineserver', '-k'], env=environment, check=False)
    subprocess.run(['wine', 'cmd', '/c', 'ver'], env=environment, stdout=wine_log,
                   stderr=subprocess.STDOUT, timeout=90, check=True)
    lifecycle_folder = private / '生命周期-中文'
    lifecycle_folder.mkdir()
    lifecycle_log = cleanup.enter_context((output / 'lifecycle.log').open('w'))
    subprocess.run(['wine', str(build / 'lrdp_bridge_test.exe'), windows_path(lifecycle_folder)],
                   cwd=build, env=environment, stdout=lifecycle_log, stderr=subprocess.STDOUT,
                   timeout=120, check=True)
    print('PASS: Windows lifecycle, cancellation and Unicode path argument', flush=True)
    observer = InputWindow(environment['DISPLAY'])
    cleanup.callback(observer.close)
    observer.events()
    subprocess.run(['xsetroot', '-solid', '#182d28'], env=environment, check=True)
    reserved = [cleanup.enter_context(socket.socket()) for _ in range(3)]
    for sock in reserved:
        sock.bind(('127.0.0.1', 0))
    graphics_port, file_port, nla_port = [sock.getsockname()[1] for sock in reserved]
    cert, key = private / 'cert.pem', private / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
    pin = ':'.join(f'{byte:02x}' for byte in hashlib.sha256(der).digest())
    digest = subprocess.run(['openssl', 'dgst', '-md4', '-provider', 'legacy'],
        input='LRDP-test-password-2026'.encode('utf-16le'), capture_output=True, check=True)
    sam = private / 'SAM'
    sam.write_text(f'lrdptest:::{digest.stdout.decode().strip().split()[-1]}:\n')
    sam.chmod(0o600)
    flags = shlex.split(subprocess.check_output(
        ['pkg-config', '--cflags', '--libs', 'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
        str(root / 'native/tests/rdp_fixture.c'), '-o', str(output / 'rdp_fixture'), *flags], check=True)
    share = private / '中文中转'
    share.mkdir()
    (share / '上传测试.txt').write_bytes('LRDP upload: 中文文件\n'.encode() + bytes(range(256)) * 4096)
    outside = private / 'outside.txt'
    outside.write_text('private outside the advertised directory')
    for sock in reserved:
        sock.close()
    server_log = cleanup.enter_context((output / 'graphics-server.log').open('w'))
    graphics = subprocess.Popen(['freerdp-shadow-cli3', '/bind-address:127.0.0.1',
        f'/port:{graphics_port}', '/sec:tls', '-auth', '+may-view', '+may-interact',
        '-gfx-avc420', '-gfx-avc444', '/log-level:WARN'],
        env=environment, stdout=server_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, graphics)
    nla_log = cleanup.enter_context((output / 'nla-server.log').open('w'))
    nla_server = subprocess.Popen(['freerdp-shadow-cli3', '/bind-address:127.0.0.1',
        f'/port:{nla_port}', '/sec:nla', f'/sam-file:{sam}', '+may-view', '+may-interact',
        '-gfx-avc420', '-gfx-avc444', '/log-level:WARN'],
        env=dict(environment, XDG_CONFIG_HOME=str(private / 'nla-config')),
        stdout=nla_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, nla_server)
    file_log = cleanup.enter_context((output / 'file-server.log').open('w'))
    files = subprocess.Popen([str(output / 'rdp_fixture'), str(file_port), str(cert), str(key), '300000'],
                             env=environment, stdout=file_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, files)
    listening(graphics, graphics_port)
    listening(files, file_port)
    listening(nla_server, nla_port)
    config_dir = private / 'protocol'
    config_dir.mkdir()
    marker = private / 'input-ready.txt'
    config = private / 'client.txt'
    config.write_text('\n'.join([str(graphics_port), str(file_port), pin,
        windows_path(config_dir), windows_path(share), windows_path(marker), str(nla_port)]) + '\n')
    protocol_log = cleanup.enter_context((output / 'protocol.log').open('w'))
    print('Running actual Windows DLL TLS, graphics, input, files and Unicode', flush=True)
    client = subprocess.Popen(['wine', str(build / 'lrdp_windows_protocol.exe'), windows_path(config)],
        cwd=build, env=environment, stdout=protocol_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, client)
    observed = set()
    changed = False
    deadline = time.monotonic() + 260
    while client.poll() is None and time.monotonic() < deadline:
        observed.update(observer.events())
        if marker.exists() and observer.complete and 6 in observed and not changed:
            subprocess.run(['xsetroot', '-solid', '#2a8465'], env=environment, check=True)
            changed = True
        time.sleep(.05)
    if client.poll() != 0:
        (output / 'RESULT.json').write_text(json.dumps({
            'result': 'failed', 'sspi_provider': args.sspi_provider,
            'core_sha256': core_sha256,
            'physical_windows': False, 'flutter_runner': False,
            'error': 'protocol client failed or timed out',
        }, indent=2) + '\n')
        raise AssertionError(f'Windows protocol client failed; see {output / "protocol.log"}')
    assert changed, f'Windows keyboard/mouse did not arrive: {observed}'
    assert files.wait(timeout=10) == 0, (output / 'file-server.log').read_text()[-4000:]
    expected = 'LRDP download: 远程写回\n'.encode() + bytes(reversed(range(256))) * 4096
    assert (share / '收到的文件.txt').read_bytes() == expected
    assert outside.read_text() == 'private outside the advertised directory'
    report = {'result': 'passed', 'runtime': subprocess.check_output(['wine', '--version'], text=True).strip(),
        'sspi_provider': args.sspi_provider,
        'core_sha256': core_sha256,
        'target': 'Windows x64 PE core', 'physical_windows': False, 'flutter_runner': False,
        'keyboard_mouse_event_types': sorted(observed), 'files': '1 MiB bidirectional exact',
        'keyboard_mouse': 'A press/release, left button press/release and motion observed on server',
        'unicode': 'Chinese directory, filenames and keyboard events',
        'tls': 'untrusted rejection, wrong pin rejection, exact pin acceptance',
        'nla': 'wrong password rejected, correct password authenticated over pinned TLS',
        'graphics': 'actual initial and changed 1280x800 BGRA palette',
        'avc_surface_decode': 'avc_decoded=1' in (output / 'protocol.log').read_text(),
        'pixel_rgb_tolerance': '4 for AVC decoded surfaces; 2 otherwise; alpha exact'}
    (output / 'VERDICT.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    (output / 'RESULT.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('PASS: Windows PE core under Wine, actual TLS/RDP graphics/input/files/Unicode', flush=True)
