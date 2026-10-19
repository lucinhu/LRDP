#!/usr/bin/env python3
"""Independent PNG/DIB goldens over private TLS; no access to a real clipboard."""
from pathlib import Path
import argparse
import ctypes as c
import hashlib
import json
import os
import random
import shlex
import socket
import struct
import subprocess
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parent.parent


def golden_images():
    # Top row RGB, bottom white/black/cyan, opaque. DIB has padded bottom-up BGR.
    rgba = bytes([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
                  255, 255, 255, 255, 0, 0, 0, 255, 0, 255, 255, 255])
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 3, 2, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(b'\0' + rgba[:12] + b'\0' + rgba[12:])) + chunk(b'IEND', b'')
    dib = struct.pack('<IiiHHIIiiII', 40, 3, 2, 1, 24, 0, 24, 0, 0, 0, 0)
    dib += bytes([255, 255, 255, 0, 0, 0, 255, 255, 0, 0, 0, 0,
                  0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0])
    return png, dib


def large_images():
    # Both payloads exceed the old 1 MiB text cap and static-channel fragments.
    width = height = 768
    source = random.Random(1717)
    rgba = bytearray()
    rows = []
    for _ in range(height):
        row = bytearray()
        for _ in range(width):
            r, g, b = source.randbytes(3)
            rgba.extend((r, g, b, 255)); row.extend((b, g, r))
        rows.append(row)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(b''.join(b'\0' + rgba[y * width * 4:(y + 1) * width * 4]
        for y in range(height)))) + chunk(b'IEND', b'')
    dib = struct.pack('<IiiHHIIiiII', 40, width, height, 1, 24, 0, width * height * 3, 0, 0, 0, 0)
    dib += b''.join(reversed(rows))
    assert len(png) > 1048576 and len(dib) > 1048576
    return png, dib


def until(predicate, label, timeout=12):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        time.sleep(.02)
    assert predicate(), label


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=ROOT / 'build/native/liblrdp.so')
    parser.add_argument('--flutter', action='store_true')
    parser.add_argument('--case')
    parser.add_argument('--large', action='store_true')
    args = parser.parse_args()
    assert not (args.flutter and args.large), 'Flutter pixel goldens use the small image'
    library = args.library.resolve()
    output = ROOT / 'build/image-clipboard' / ('flutter-protocol' if args.flutter else
        'release-protocol' if library.parent == ROOT / 'build/linux/x64/release/bundle/lib' else 'native-protocol')
    if args.large: output = output.with_name(output.name + '-large')
    output.mkdir(parents=True, exist_ok=True)
    verdict = output / ('VERDICT-' + args.case + '.json' if args.case else 'VERDICT.json')
    verdict.unlink(missing_ok=True)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs',
        'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
    fixture = output / 'peer'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
        str(ROOT / 'native/tests/paste_fixture.c'), '-o', str(fixture), *flags], check=True)
    api = c.CDLL(str(library))
    for name, restype, types in [
        ('lrdp_create', c.c_void_p, []), ('lrdp_destroy', None, [c.c_void_p]),
        ('lrdp_start', c.c_int, [c.c_void_p]), ('lrdp_state', c.c_int, [c.c_void_p]),
        ('lrdp_features', c.c_int, [c.c_void_p]),
        ('lrdp_set', c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p]),
        ('lrdp_paste', c.c_int, [c.c_void_p, c.c_char_p]),
        ('lrdp_clipboard', c.c_int, [c.c_void_p, c.c_char_p]),
        ('lrdp_read', c.c_int, [c.c_void_p, c.c_int, c.c_void_p, c.c_size_t]),
        ('lrdp_paste_image', c.c_int, [c.c_void_p, c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]),
        ('lrdp_read_image', c.c_int, [c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_int32)]),
    ]:
        function = getattr(api, name); function.restype = restype; function.argtypes = types
    modes = ['image_normal', 'image_dib', 'image_mime', 'image_prefetch', 'image_reject',
             'image_no_ack', 'image_no_data', 'image_cancel', 'receive_png', 'receive_dib',
             'receive_stale', 'receive_invalid', 'receive_clear']
    if args.flutter: modes = ['image_dib', 'receive_png', 'receive_stale']
    if args.case:
        assert args.case in modes
        modes = [args.case]
    reports = []
    with tempfile.TemporaryDirectory(prefix='lrdp-image-') as temporary:
        directory = Path(temporary)
        cert, key = directory / 'cert.pem', directory / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
            '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
        der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
        pin = ':'.join(f'{value:02x}' for value in hashlib.sha256(der).digest())
        png, dib = large_images() if args.large else golden_images()
        png_file, dib_file = directory / 'test.png', directory / 'test.dib'
        png_file.write_bytes(png); dib_file.write_bytes(dib)
        for mode in modes:
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
            config = directory / mode; config.mkdir()
            env = dict(os.environ, WLOG_LEVEL='WARN', XDG_CONFIG_HOME=str(config),
                LRDP_NATIVE_LIBRARY=str(library), LRDP_TEST_PORT=str(port), LRDP_TEST_PIN=pin,
                LRDP_IMAGE_MODE=mode, LRDP_TEST_PNG=str(png_file), LRDP_TEST_DIB=str(dib_file))
            with (output / (mode + '.log')).open('w') as log:
                peer = subprocess.Popen([str(fixture), str(port), str(cert), str(key), mode,
                    '180000' if args.flutter else '20000', '120000' if args.flutter else '12000',
                    str(png_file), str(dib_file)], env=env, stdout=log, stderr=subprocess.STDOUT)
                session = None
                try:
                    def listening():
                        return any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                            for line in Path('/proc/net/tcp').read_text().splitlines()[1:])
                    until(listening, 'private listener')
                    if args.flutter:
                        subprocess.run(['flutter', 'test', 'test/session_image_protocol_test.dart',
                            '--no-pub', '--reporter', 'expanded'], env=env, cwd=ROOT, check=True, timeout=240)
                    else:
                        session = api.lrdp_create(); assert session
                        for key_name, value in {'host': '127.0.0.1', 'port': str(port), 'username': 'test',
                            'nla': '0', 'clipboard': '1', 'fingerprint': pin, 'config_path': str(config)}.items():
                            assert api.lrdp_set(session, key_name.encode(), value.encode())
                        assert api.lrdp_start(session)
                        until(lambda: api.lrdp_state(session) == 2 and api.lrdp_features(session) & 16,
                            'TLS connection and clipboard')
                        if mode.startswith('receive_'):
                            if mode == 'receive_invalid':
                                time.sleep(.5)
                                assert api.lrdp_read_image(session, None, 0, None) == 0
                            else:
                                until(lambda: api.lrdp_read_image(session, None, 0, None) < 0, 'received image')
                                if mode == 'receive_clear':
                                    assert api.lrdp_clipboard(session, b'local priority')
                                    assert api.lrdp_read_image(session, None, 0, None) == 0
                                    time.sleep(.5)
                                else:
                                    expected = dib if mode in ('receive_dib', 'receive_stale') else png
                                    size = len(expected); kind = c.c_int32(); buffer = c.create_string_buffer(size)
                                    assert api.lrdp_read_image(session, buffer, 1, c.byref(kind)) == -size
                                    assert api.lrdp_read_image(session, buffer, size, c.byref(kind)) == size
                                    assert buffer.raw == expected
                                    assert kind.value == (2 if expected == dib else 1)
                                    assert api.lrdp_read_image(session, None, 0, None) == 0
                        else:
                            a, b = c.create_string_buffer(png), c.create_string_buffer(dib)
                            assert api.lrdp_paste_image(session, a, len(png), b, len(dib)) == 1
                            assert not api.lrdp_paste_image(session, a, len(png), b, len(dib))
                            assert not api.lrdp_paste(session, b'must not replace image')
                            c.memset(a, 0, len(png)); c.memset(b, 0, len(dib))
                            if mode == 'image_cancel': time.sleep(.05)
                            else:
                                status = c.create_string_buffer(32)
                                def finished():
                                    api.lrdp_read(session, 3, status, len(status))
                                    return status.value != b'pending'
                                until(finished, 'bounded paste confirmation')
                                expected = b'rejected' if mode == 'image_reject' else b'timeout' if mode in (
                                    'image_no_ack', 'image_no_data') else b'sent'
                                assert status.value == expected, (mode, status.value, expected)
                                if expected == b'sent':
                                    # Channel writes are asynchronous. Keep the session open
                                    # until the independent peer has checked every fragment.
                                    until(lambda: 'PASS: full image payload received' in
                                        (output / (mode + '.log')).read_text(), 'complete image delivery')
                        assert api.lrdp_state(session) == 2
                        api.lrdp_destroy(session); session = None
                    assert peer.wait(timeout=8) == 0, (mode, 'peer failed')
                    report = next(json.loads(line) for line in (output / (mode + '.log')).read_text().splitlines()
                                  if line.startswith('{"mode"'))
                    assert report['passed'], report
                    reports.append(report)
                    print('PASS:', mode, flush=True)
                finally:
                    if session: api.lrdp_destroy(session)
                    if peer.poll() is None:
                        peer.terminate()
                        try: peer.wait(timeout=5)
                        except subprocess.TimeoutExpired: peer.kill(); peer.wait()
    verdict.write_text(json.dumps({'passed': True, 'abi': 5,
        'payload_bytes': {'png': len(png), 'dib': len(dib)},
        'library_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
        'scope': 'private TLS image protocol, no real server application', 'cases': reports}, indent=2) + '\n')


if __name__ == '__main__': main()
