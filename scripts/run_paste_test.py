#!/usr/bin/env python3
"""Exercise bounded clipboard paste over private TLS, without any real desktop."""
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
parser.add_argument('--library', type=Path)
parser.add_argument('--asan', action='store_true')
parser.add_argument('--wine', action='store_true')
parser.add_argument('--flutter', action='store_true')
args = parser.parse_args()
assert sum((args.flutter, args.asan, args.wine)) <= 1
assert not (args.library and (args.asan or args.wine))
mode_name = 'flutter' if args.flutter else 'asan' if args.asan else 'wine' if args.wine else 'native'
if args.library:
    mode_name += '-release' if args.library.resolve().parent == root / 'build/linux/x64/release/bundle/lib' else '-custom'
library = (args.library or root / ('build/windows-x64/lrdp.dll' if args.wine else 'build/native-asan/liblrdp.so' if args.asan else 'build/native/liblrdp.so')).resolve()
output = root / 'build/paste-runtime' / mode_name
output.mkdir(parents=True, exist_ok=True)
(output / 'VERDICT.json').unlink(missing_ok=True)
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs',
    'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
fixture = output / 'paste_fixture'
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
    str(root / 'native/tests/paste_fixture.c'), '-o', str(fixture), *flags], check=True)
def until(predicate, label, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        time.sleep(.02)
    assert predicate(), label

results = []
with tempfile.TemporaryDirectory(prefix='lrdp-paste-test-') as private:
    directory = Path(private)
    cert, key = directory / 'cert.pem', directory / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
    pin = ':'.join(f'{value:02x}' for value in hashlib.sha256(der).digest())
    modes = ('unicode', 'unicode_unsupported', 'normal', 'cancel') if args.flutter else ('normal', 'prefetch', 'reject', 'no_ack', 'no_data', 'cancel')
    for mode in modes:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        env = dict(os.environ, WLOG_LEVEL='WARN', XDG_CONFIG_HOME=str(directory / mode),
            LRDP_NATIVE_LIBRARY=str(library), LRDP_TEST_PORT=str(port),
            LRDP_TEST_PIN=pin, LRDP_PASTE_MODE=mode)
        log_path = output / (mode + '.log')
        with log_path.open('w') as log:
            server = subprocess.Popen([str(fixture), str(port), str(cert), str(key), mode],
                env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                def listening():
                    return any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                        for line in Path('/proc/net/tcp').read_text().splitlines()[1:])
                until(listening, f'{mode}: fixture listener')
                if args.flutter:
                    subprocess.run(['flutter', 'test', 'test/session_paste_protocol_test.dart',
                        '--reporter', 'expanded', '--no-pub'], cwd=root, env=env, check=True)
                else:
                    binary = root / ('build/windows-x64/lrdp_paste_test.exe' if args.wine else
                        'build/native-asan/lrdp_paste_test' if args.asan else 'build/native/lrdp_paste_test')
                    if not binary.exists():
                        raise RuntimeError(f'Build the lrdp_paste_test target first: {binary}')
                    client_env = dict(env, LD_LIBRARY_PATH=str(library.parent) + ':' + env.get('LD_LIBRARY_PATH', ''))
                    config = str(directory / mode)
                    if args.wine:
                        prefix = root / 'build/windows-runtime/wineprefix'
                        if not (prefix / '.update-timestamp').exists():
                            raise RuntimeError('Initialize the private prefix with run_windows_test.py first')
                        client_env.update(WINEPREFIX=str(prefix), WINEDEBUG='-all',
                            WINEDLLOVERRIDES='mscoree,mshtml=', DISPLAY='')
                        config = subprocess.check_output(['winepath', '-w', config], env=client_env, text=True).strip()
                    if args.asan:
                        client_env.update(ASAN_OPTIONS='detect_leaks=1:halt_on_error=1',
                            UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
                    command = (['wine'] if args.wine else []) + [str(binary), str(port), pin, mode, config]
                    with (output / (mode + '-client.log')).open('w') as client_log:
                        subprocess.run(command, env=client_env, stdout=client_log,
                            stderr=subprocess.STDOUT, check=True, timeout=30)
                assert server.wait(timeout=8) == 0, f'{mode}: peer failed, see {log_path}'
                report = next(json.loads(line) for line in log_path.read_text().splitlines() if line.startswith('{"mode"'))
                assert report['passed'], report
                results.append(report)
                print(f'PASS: clipboard paste {mode}', flush=True)
            finally:
                if server.poll() is None:
                    server.terminate()
                    try: server.wait(timeout=5)
                    except subprocess.TimeoutExpired: server.kill(); server.wait()
(output / 'VERDICT.json').write_text(json.dumps({'passed': True, 'abi': 5,
    'library_sha256': hashlib.sha256(library.read_bytes()).hexdigest(), 'cases': results}, indent=2) + '\n')
