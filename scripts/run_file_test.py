#!/usr/bin/env python3
"""Private TLS/RDPDR file roundtrip and Unicode input integration test.

Requires system FreeRDP 3 server development libraries, cc and OpenSSL CLI.
The client under test is the vendored LRDP bridge. Never shares user folders.
"""
from pathlib import Path
import ctypes as c
import hashlib
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
library = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / 'build/native/liblrdp.so'
flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations', str(root / 'native/tests/rdp_fixture.c'), '-o', str(root / 'build/rdp_fixture'), *flags], check=True)
lib = c.CDLL(str(library))
lib.lrdp_create.restype = c.c_void_p
lib.lrdp_set.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
lib.lrdp_start.argtypes = [c.c_void_p]
lib.lrdp_state.argtypes = [c.c_void_p]
lib.lrdp_read.argtypes = [c.c_void_p, c.c_int, c.c_void_p, c.c_size_t]
lib.lrdp_input.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int, c.c_int]
lib.lrdp_destroy.argtypes = [c.c_void_p]
lib.lrdp_frame.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_int32), c.POINTER(c.c_int32), c.POINTER(c.c_uint64)]
with tempfile.TemporaryDirectory(prefix='lrdp-file-test-') as temp:
    directory = Path(temp)
    share = directory / '中文中转'; share.mkdir()
    (share / '上传测试.txt').write_bytes('LRDP upload: 中文文件\n'.encode() + bytes(range(256)) * 4096)
    (directory / 'outside.txt').write_text('private outside the advertised directory')
    cert, key = directory / 'cert.pem', directory / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1', '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
    fingerprint = ':'.join(f'{b:02x}' for b in hashlib.sha256(der).digest())
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    log_path = root / 'build/file-server.log'
    with log_path.open('w') as log:
        env = dict(os.environ, WLOG_LEVEL='WARN', XDG_CONFIG_HOME=str(directory / 'config'))
        server = subprocess.Popen([str(root / 'build/rdp_fixture'), str(port), str(cert), str(key)], env=env, stdout=log, stderr=subprocess.STDOUT)
        session = None
        try:
            ready = False
            for _ in range(100):
                for entry in Path('/proc/net/tcp').read_text().splitlines()[1:]:
                    fields = entry.split()
                    if fields[1] == f'0100007F:{port:04X}' and fields[3] == '0A': ready = True
                if ready or server.poll() is not None: break
                time.sleep(.05)
            assert ready, 'Fixture did not listen; see build/file-server.log'
            session = lib.lrdp_create(); assert session
            for name, value in dict(host='127.0.0.1', port=str(port), username='test', nla='0', clipboard='0', fingerprint=fingerprint, drive_path=str(share)).items():
                assert lib.lrdp_set(session, name.encode(), value.encode()), name
            assert lib.lrdp_start(session)
            deadline = time.monotonic() + 20
            while lib.lrdp_state(session) == 1 and time.monotonic() < deadline: time.sleep(.02)
            error = c.create_string_buffer(4096)
            lib.lrdp_read(session, 0, error, len(error))
            assert lib.lrdp_state(session) == 2, error.value.decode()
            # This fixture never paints. Connection setup must not invent an
            # initial desktop image from GDI's untouched framebuffer.
            width, height, generation = c.c_int32(), c.c_int32(), c.c_uint64()
            assert lib.lrdp_frame(session, None, 0, c.byref(width), c.byref(height), c.byref(generation)) == 0
            for unit in [ord(ch) for ch in '中文输入']:
                assert lib.lrdp_input(session, 2, 0, unit, 0)
                assert lib.lrdp_input(session, 2, 0x8000, unit, 0)
            assert server.wait(timeout=25) == 0, log_path.read_text()[-5000:]
            assert (share / '收到的文件.txt').read_bytes() == 'LRDP download: 远程写回\n'.encode() + bytes(reversed(range(256))) * 4096
            assert (directory / 'outside.txt').read_text() == 'private outside the advertised directory'
            print(log_path.read_text())
            print('PASS: real pinned TLS, 1 MiB bidirectional files, Chinese filenames, traversal refusal and Unicode input')
        finally:
            if session: lib.lrdp_destroy(session)
            if server.poll() is None:
                server.terminate()
                try: server.wait(timeout=5)
                except subprocess.TimeoutExpired: server.kill(); server.wait()
