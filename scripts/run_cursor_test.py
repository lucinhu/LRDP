#!/usr/bin/env python3
"""Private TLS pointer fixture for Linux, Flutter and the Windows PE core."""
from contextlib import ExitStack
from pathlib import Path
import argparse
import hashlib
import json
import os
import shlex
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--flutter', action='store_true')
parser.add_argument('--wine', action='store_true')
parser.add_argument('--asan', action='store_true')
parser.add_argument('--library', type=Path)
args = parser.parse_args()
assert sum((args.flutter, args.wine, args.asan)) <= 1
assert not (args.library and (args.wine or args.asan))
mode = 'asan' if args.asan else 'wine' if args.wine else 'flutter' if args.flutter else 'native'
if args.library: mode += '-release'
library = args.library.resolve() if args.library else root / 'build/native/liblrdp.so'
output = root / 'build/cursor-runtime' / mode
output.mkdir(parents=True, exist_ok=True)
(output / 'VERDICT.json').unlink(missing_ok=True)
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
fixture = output / 'cursor_fixture'
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
    str(root / 'native/tests/cursor_fixture.c'), '-o', str(fixture), *flags], check=True)

def stop(process):
    if process.poll() is None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()

with tempfile.TemporaryDirectory(prefix='lrdp-cursor-') as temp, ExitStack() as cleanup:
    private = Path(temp)
    env = dict(os.environ, XDG_CONFIG_HOME=str(private / 'config'), WLOG_LEVEL='WARN')
    cert, key = private / 'cert.pem', private / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    digest = hashlib.sha256(subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])).digest()
    pin = ':'.join(f'{byte:02x}' for byte in digest)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    if args.wine:
        prefix = root / 'build/windows-runtime/wineprefix'
        assert (prefix / 'system.reg').exists(), 'Initialize the private prefix with run_windows_test.py first'
        display = next(n for n in range(101, 201) if not Path(f'/tmp/.X11-unix/X{n}').exists())
        env.update(DISPLAY=f':{display}', WINEPREFIX=str(prefix), WINEARCH='win64',
                   WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=', WINPR_NATIVE_SSPI='0')
        log = cleanup.enter_context((output / 'display.log').open('w'))
        desktop = subprocess.Popen(['Xvnc', env['DISPLAY'], '-geometry', '800x600', '-depth', '24',
            '-SecurityTypes', 'None', '-noreset', '-rfbport', '-1', '-rfbunixpath', str(private / 'vnc.sock'),
            '-rfbunixmode', '0600', '-nolisten', 'tcp'], env=env, stdout=log, stderr=subprocess.STDOUT)
        cleanup.callback(stop, desktop)
        for _ in range(200):
            assert desktop.poll() is None
            if Path(f'/tmp/.X11-unix/X{display}').exists(): break
            time.sleep(.05)
        else: raise RuntimeError('Private cursor test display failed')
        cleanup.callback(subprocess.run, ['wineserver', '-k'], env=env, check=False,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = cleanup.enter_context((output / 'server.log').open('w'))
    server = subprocess.Popen([str(fixture), str(port), str(cert), str(key)], env=env, stdout=log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, server)
    for _ in range(200):
        assert server.poll() is None, 'Cursor fixture exited early'
        if any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
               for line in Path('/proc/net/tcp').read_text().splitlines()[1:]): break
        time.sleep(.05)
    else: raise RuntimeError('Cursor fixture failed to listen')
    if args.flutter:
        env.update(LRDP_CURSOR_PORT=str(port), LRDP_CURSOR_PIN=pin,
                   LRDP_NATIVE_LIBRARY=str(library))
        command = ['flutter', 'test', 'test/rdp_cursor_protocol_test.dart', '--no-pub', '--reporter', 'expanded']
    else:
        binary = root / ('build/windows-x64/lrdp_cursor_test.exe' if args.wine else 'build/native-asan/lrdp_cursor_test' if args.asan else 'build/native/lrdp_cursor_test')
        command = (['wine'] if args.wine else []) + [str(binary), str(port), pin]
    if args.library:
        env['LD_LIBRARY_PATH']=str(library.parent)+':'+env.get('LD_LIBRARY_PATH','')
    if args.asan:
        env.update(ASAN_OPTIONS='detect_leaks=1:halt_on_error=1', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    subprocess.run(command, cwd=root, env=env, check=True, timeout=120)
    assert server.wait(timeout=10) == 0, (output / 'server.log').read_text()[-4000:]
    report = {'result':'passed', 'mode':mode, 'abi':5, 'tls':'exact pin',
        'cases':['premultiplied alpha','null/default','cached shapes','monochrome and color XOR inversion',
                 'server position without shape change','384x384 large pointer','snapshot capacity/generation'],
        'physical_device':False}
    if args.wine:
        report['core_sha256'] = hashlib.sha256((root / 'build/windows-x64/lrdp.dll').read_bytes()).hexdigest()
    (output / 'VERDICT.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: {mode} actual TLS cursor protocol and lifetime regression')
