#!/usr/bin/env python3
"""Private TLS file clipboard oracle: exact Unicode names and binary ranges."""
from pathlib import Path
import argparse
import ctypes as c
import hashlib
import json
import os
import shlex
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def until(predicate, label, timeout=15):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        time.sleep(.02)
    assert predicate(), label


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=ROOT / 'build/native/liblrdp.so')
    parser.add_argument('--flutter', action='store_true')
    parser.add_argument('--case')
    args = parser.parse_args()
    library = args.library.resolve()
    output = ROOT / 'build/file-clipboard' / ('flutter-protocol' if args.flutter else
        'release-protocol' if 'release/bundle' in str(library) else 'native-protocol')
    output.mkdir(parents=True, exist_ok=True)
    verdict = output / (f'VERDICT-{args.case}.json' if args.case else 'VERDICT.json')
    verdict.unlink(missing_ok=True)
    fixture = output / 'peer'
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs',
        'freerdp-server3', 'freerdp3', 'winpr3'], text=True))
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
        str(ROOT / 'native/tests/paste_fixture.c'), '-o', str(fixture), *flags], check=True)
    api = c.CDLL(str(library))
    for name, restype, types in [
        ('lrdp_create', c.c_void_p, []), ('lrdp_destroy', None, [c.c_void_p]),
        ('lrdp_start', c.c_int, [c.c_void_p]), ('lrdp_state', c.c_int, [c.c_void_p]),
        ('lrdp_features', c.c_int, [c.c_void_p]),
        ('lrdp_set', c.c_int, [c.c_void_p, c.c_char_p, c.c_char_p]),
        ('lrdp_paste_files', c.c_int, [c.c_void_p, c.POINTER(c.c_char_p), c.c_size_t]),
        ('lrdp_paste', c.c_int, [c.c_void_p, c.c_char_p]),
        ('lrdp_clipboard', c.c_int, [c.c_void_p, c.c_char_p]),
        ('lrdp_read', c.c_int, [c.c_void_p, c.c_int, c.c_void_p, c.c_size_t]),
    ]:
        function = getattr(api, name); function.restype = restype; function.argtypes = types
    modes = ['normal', 'prefetch', 'revoke', 'replace', 'reject', 'no_ack', 'no_data', 'cancel', 'cancel_stream', 'unsupported']
    if args.flutter: modes = ['normal', 'unsupported']
    if args.case:
        assert args.case in modes
        modes = [args.case]
    reports = []
    with tempfile.TemporaryDirectory(prefix='lrdp-file-protocol-') as temporary:
        directory = Path(temporary)
        cert, key = directory / 'cert.pem', directory / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-noenc', '-days', '1',
            '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
        der = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-outform', 'DER'])
        pin = ':'.join(f'{value:02x}' for value in hashlib.sha256(der).digest())
        for mode in modes:
            case = directory / mode; case.mkdir()
            files = [case / '中文 😀.bin', case / 'empty.txt', case / 'second.bin']
            files[0].write_bytes(bytes((i * 31 + 17) % 256 for i in range(1048576 + 731)))
            files[1].touch(); files[2].write_bytes(bytes((i * 13 + 9) % 256 for i in range(12345)))
            config = case / 'config'; config.mkdir()
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
            log_path = output / (mode + '.log')
            env = dict(os.environ, WLOG_LEVEL='WARN', XDG_CONFIG_HOME=str(config),
                LRDP_NATIVE_LIBRARY=str(library), LRDP_TEST_PORT=str(port), LRDP_TEST_PIN=pin,
                LRDP_FILE_MODE=mode, LRDP_TEST_FILES=json.dumps([str(f) for f in files]),
                LRDP_TEST_PEER_LOG=str(log_path))
            with log_path.open('w') as log:
                peer = subprocess.Popen([str(fixture), str(port), str(cert), str(key), 'file_' + mode,
                    '180000' if args.flutter else '20000', '120000' if args.flutter else '20000'],
                    env=env, stdout=log, stderr=subprocess.STDOUT)
                session = None
                try:
                    def listening():
                        return any(line.split()[1] == f'0100007F:{port:04X}' and line.split()[3] == '0A'
                            for line in Path('/proc/net/tcp').read_text().splitlines()[1:])
                    until(listening, 'private listener')
                    if args.flutter:
                        subprocess.run(['flutter', 'test', 'test/session_file_protocol_test.dart',
                            '--no-pub', '--reporter', 'expanded'], cwd=ROOT, env=env, check=True, timeout=240)
                    else:
                        session = api.lrdp_create(); assert session
                        for name, value in {'host': '127.0.0.1', 'port': str(port), 'username': 'test',
                            'nla': '0', 'clipboard': '1', 'fingerprint': pin, 'config_path': str(config)}.items():
                            assert api.lrdp_set(session, name.encode(), value.encode())
                        assert api.lrdp_start(session)
                        until(lambda: api.lrdp_state(session) == 2 and api.lrdp_features(session) & 16,
                            'TLS and clipboard ready')
                        paths = (c.c_char_p * 3)(*[str(f).encode() for f in files])
                        assert bool(api.lrdp_features(session) & 32) == (mode != 'unsupported')
                        accepted = api.lrdp_paste_files(session, paths, 3)
                        assert accepted == (mode != 'unsupported')
                        if mode == 'unsupported': time.sleep(.3)
                        else:
                            assert not api.lrdp_paste_files(session, paths, 3)
                            assert not api.lrdp_paste(session, b'duplicate')
                            # Prove all future requests use pinned handles, not reopened paths.
                            for file in files: file.unlink()
                            if mode == 'cancel': time.sleep(.05)
                            else:
                                status = c.create_string_buffer(32)
                                def finished():
                                    api.lrdp_read(session, 3, status, len(status))
                                    return status.value != b'pending'
                                until(finished, 'single bounded paste result')
                                expected = b'rejected' if mode == 'reject' else b'timeout' if mode in (
                                    'no_ack', 'no_data') else b'sent'
                                assert status.value == expected, (mode, status.value)
                                if mode == 'no_ack': assert not api.lrdp_paste(session, b'late ACK barrier')
                                if mode == 'replace':
                                    until(lambda: 'READY: replace local clipboard' in log_path.read_text(), 'descriptor received')
                                    assert api.lrdp_clipboard(session, b'replacement')
                                if expected == b'sent':
                                    marker = 'READY: blocked file reader' if mode == 'cancel_stream' else 'PASS: full files and invalid requests checked'
                                    until(lambda: marker in log_path.read_text(),
                                        'complete independent file validation')
                        assert api.lrdp_state(session) == 2
                        started = time.monotonic(); api.lrdp_destroy(session); session = None
                        assert time.monotonic() - started < 3, 'bounded teardown'
                    assert peer.wait(timeout=8) == 0, (mode, log_path.read_text()[-3000:])
                    report = next(json.loads(line) for line in log_path.read_text().splitlines() if line.startswith('{"mode"'))
                    assert report['passed'], report
                    reports.append(report); print('PASS:', mode, flush=True)
                finally:
                    if session: api.lrdp_destroy(session)
                    if peer.poll() is None:
                        peer.terminate()
                        try: peer.wait(timeout=5)
                        except subprocess.TimeoutExpired: peer.kill(); peer.wait()
    verdict.write_text(json.dumps({'passed': True, 'abi': 5,
        'library_sha256': hashlib.sha256(library.read_bytes()).hexdigest(),
        'scope': 'private TLS file protocol; no real remote file manager', 'cases': reports}, indent=2) + '\n')


if __name__ == '__main__':
    main()
