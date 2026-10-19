#!/usr/bin/env python3
"""Verify server ErrorInfo logoff is terminal rather than a retryable TCP loss."""
from pathlib import Path
import ctypes as c
import hashlib
import os
import shlex
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs',
    'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
fixture = root / 'build/logoff_fixture'
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
    str(root / 'native/tests/logoff_fixture.c'), '-o', str(fixture), *flags], check=True)
lib = c.CDLL(str(root / 'build/native/liblrdp.so'))
lib.lrdp_create.restype = c.c_void_p
lib.lrdp_set.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
for name in ('start', 'state', 'end_reason', 'error_code', 'stop', 'destroy'):
    getattr(lib, 'lrdp_' + name).argtypes = [c.c_void_p]
lib.lrdp_error_code.restype = c.c_uint32
with tempfile.TemporaryDirectory(prefix='lrdp-logoff-') as temp:
    path = Path(temp)
    cert, key = path / 'cert.pem', path / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc',
        '-days', '1', '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)],
        check=True, capture_output=True)
    digest = hashlib.sha256(subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])).digest()
    pin = ':'.join(f'{byte:02x}' for byte in digest)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    with (root / 'build/logoff-server.log').open('w') as log:
        server = subprocess.Popen([str(fixture), str(port), str(cert), str(key)],
            env=dict(os.environ, XDG_CONFIG_HOME=str(path / 'config'), WLOG_LEVEL='WARN'),
            stdout=log, stderr=subprocess.STDOUT)
        session = None
        try:
            for _ in range(100):
                if server.poll() is not None: raise AssertionError('Logoff fixture exited early')
                if any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                       for line in Path('/proc/net/tcp').read_text().splitlines()[1:]): break
                time.sleep(.05)
            else: raise AssertionError('Logoff fixture failed to listen')
            session = lib.lrdp_create(); assert session
            for name, value in dict(host='127.0.0.1', port=str(port), username='test',
                password='', nla='0', fingerprint=pin).items():
                assert lib.lrdp_set(session, name.encode(), value.encode())
            assert lib.lrdp_start(session)
            connected = False
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                state = lib.lrdp_state(session)
                if state == 2: connected = True
                if state >= 3: break
                time.sleep(.01)
            assert connected, 'Session must have actually connected before logoff'
            assert lib.lrdp_state(session) == 3, lib.lrdp_state(session)
            assert lib.lrdp_end_reason(session) == 5, lib.lrdp_end_reason(session)
            assert lib.lrdp_error_code(session) == 0x1000c, hex(lib.lrdp_error_code(session))
            assert server.wait(timeout=5) == 0
            print('PASS: real TLS ErrorInfo(LOGOFF_BY_USER) -> closed/remote; no transport retry classification')
        finally:
            if session: lib.lrdp_destroy(session)
            if server.poll() is None:
                server.terminate()
                try: server.wait(timeout=5)
                except subprocess.TimeoutExpired: server.kill(); server.wait()
