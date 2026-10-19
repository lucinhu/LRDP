#!/usr/bin/env python3
"""Validate real CredSSP/NLA on the isolated SAM-backed shadow server."""
import ctypes as c
import os
import sys
import time

lib = c.CDLL(sys.argv[1])
lib.lrdp_create.restype = c.c_void_p
lib.lrdp_set.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
lib.lrdp_start.argtypes = [c.c_void_p]
lib.lrdp_state.argtypes = [c.c_void_p]
lib.lrdp_end_reason.argtypes = [c.c_void_p]
lib.lrdp_read.argtypes = [c.c_void_p, c.c_int, c.c_void_p, c.c_size_t]
lib.lrdp_destroy.argtypes = [c.c_void_p]

def field(session, key):
    buffer = c.create_string_buffer(4096)
    assert lib.lrdp_read(session, key, buffer, len(buffer)) >= 0
    return buffer.value.decode()

def connect(password, fingerprint=''):
    session = lib.lrdp_create()
    assert session
    try:
        for key, value in {'host': '127.0.0.1', 'port': os.environ['LRDP_TEST_PORT'],
            'username': 'lrdptest', 'domain': '', 'password': password,
            'nla': '1', 'fingerprint': fingerprint}.items():
            assert lib.lrdp_set(session, key.encode(), value.encode())
        assert lib.lrdp_start(session)
        deadline = time.monotonic() + 20
        while lib.lrdp_state(session) == 1 and time.monotonic() < deadline:
            time.sleep(.02)
        return session
    except BaseException:
        lib.lrdp_destroy(session)
        raise

s = connect('wrong-password')
try:
    assert lib.lrdp_state(s) == 5, (lib.lrdp_state(s), field(s, 0))
    fingerprint = field(s, 1)
finally:
    lib.lrdp_destroy(s)
s = connect('wrong-password', fingerprint)
try:
    assert lib.lrdp_state(s) == 4, (lib.lrdp_state(s), field(s, 0))
    assert lib.lrdp_end_reason(s) == 3, 'Wrong credentials must not be retryable'
    assert 'log' in field(s, 0).lower() or 'auth' in field(s, 0).lower(), field(s, 0)
    print('PASS: NLA rejects incorrect credentials', flush=True)
finally:
    lib.lrdp_destroy(s)
s = connect('LRDP-test-password-2026', fingerprint)
try:
    assert lib.lrdp_state(s) == 2, (lib.lrdp_state(s), field(s, 0))
    print('PASS: NLA/CredSSP authenticates correct credentials over pinned TLS', flush=True)
finally:
    lib.lrdp_destroy(s)
