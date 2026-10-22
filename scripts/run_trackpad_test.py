#!/usr/bin/env python3
"""Synthetic desktop gestures -> production Flutter/FFI worker -> private TLS peer.

This verifies the input stream, not a physical trackpad or an OS gesture driver.
"""
from contextlib import ExitStack
from pathlib import Path
import hashlib
import json
import os
import shlex
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
output = root / 'build/trackpad-runtime'
output.mkdir(parents=True, exist_ok=True)
verdict = output / 'VERDICT.json'
verdict.unlink(missing_ok=True)
flags = shlex.split(subprocess.check_output([
    'pkg-config', '--cflags', '--libs', 'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
fixture = output / 'trackpad_fixture'
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
    str(root / 'native/tests/input_stop_fixture.c'), '-o', str(fixture), *flags], check=True)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


with tempfile.TemporaryDirectory(prefix='lrdp-trackpad-') as temporary, ExitStack() as cleanup:
    private = Path(temporary)
    cert, key = private / 'cert.pem', private / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    digest = hashlib.sha256(subprocess.check_output([
        'openssl', 'x509', '-in', str(cert), '-outform', 'DER'])).digest()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    library = Path(os.environ.get('LRDP_NATIVE_LIBRARY', str(root / 'build/native/liblrdp.so'))).resolve()
    environment = dict(os.environ, XDG_CONFIG_HOME=str(private / 'config'), WLOG_LEVEL='WARN',
        LRDP_TRACKPAD_PORT=str(port), LRDP_TRACKPAD_PIN=':'.join(f'{x:02x}' for x in digest),
        LRDP_DISABLE_TEXTURES='1', LRDP_NATIVE_LIBRARY=str(library))
    server_log = cleanup.enter_context((output / 'server.log').open('w'))
    server = subprocess.Popen([str(fixture), str(port), str(cert), str(key), 'trackpad'],
        env=environment, stdout=server_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, server)
    for _ in range(200):
        assert server.poll() is None, 'Fixture exited early'
        if any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
               for line in Path('/proc/net/tcp').read_text().splitlines()[1:]):
            break
        time.sleep(.025)
    else:
        raise RuntimeError('Loopback fixture did not listen')
    client_log = cleanup.enter_context((output / 'flutter.log').open('w'))
    client = subprocess.Popen(['flutter', 'test', '--no-pub',
        'test/trackpad_protocol_test.dart', '--reporter', 'expanded'],
        cwd=root, env=environment, stdout=client_log, stderr=subprocess.STDOUT)
    cleanup.callback(stop, client)
    assert client.wait(timeout=150) == 0, 'Flutter trackpad test failed: ' + str(output / 'flutter.log')
    assert server.wait(timeout=5) == 0, 'Incorrect wheel stream: ' + str(output / 'server.log')
    result = next(json.loads(line) for line in (output / 'server.log').read_text().splitlines()
        if line.startswith('{"trackpad_passed"'))
    assert result['trackpad_passed'] and result['wheel_pdus'] == 10
    assert result['pointer_speed_moves'] == 2
    result.update(passed=True, library_sha256=hashlib.sha256(library.read_bytes()).hexdigest(),
        scope='synthetic Flutter desktop trackpad and mouse-wheel events through real worker/FFI/TLS; physical hardware pending')
    verdict.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
