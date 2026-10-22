#!/usr/bin/env python3
"""Reject a new-host ABI, missing Flutter payload, or incomplete AppDir."""
from pathlib import Path
import ctypes
import hashlib
import json
import os
import re
import subprocess
import sys

appdir = Path(sys.argv[1]).resolve()
tools = json.loads(Path(sys.argv[2]).read_text())
for relative in ('AppRun', 'AppRun.gtk', 'dev.lrdp.lrdp.desktop', 'dev.lrdp.lrdp.png',
                 'usr/bin/lrdp', 'usr/bin/data/icudtl.dat',
                 'usr/lib/libapp.so', 'usr/lib/liblrdp.so',
                 'usr/lib/liblrdp_native_plugin.so', 'usr/lib/libflutter_linux_gtk.so',
                 'usr/lib/ossl-modules/legacy.so'):
    if not (appdir / relative).exists():
        raise SystemExit(f'AppDir payload missing: {relative}')
if not (appdir / 'usr/bin/data/flutter_assets').is_dir():
    raise SystemExit('Flutter assets are missing')
bridge = ctypes.CDLL(str(appdir / 'usr/lib/liblrdp.so'))
if bridge.lrdp_abi_version() != 5:
    raise SystemExit('Unexpected native ABI')
crypto = ctypes.CDLL(str(appdir / 'usr/lib/libcrypto.so.3'))
crypto.OSSL_PROVIDER_set_default_search_path.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
crypto.OSSL_PROVIDER_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
crypto.OSSL_PROVIDER_load.restype = ctypes.c_void_p
crypto.OSSL_PROVIDER_unload.argtypes = [ctypes.c_void_p]
crypto.EVP_MD_fetch.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
crypto.EVP_MD_fetch.restype = ctypes.c_void_p
crypto.EVP_MD_free.argtypes = [ctypes.c_void_p]
crypto.EVP_CIPHER_fetch.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
crypto.EVP_CIPHER_fetch.restype = ctypes.c_void_p
crypto.EVP_CIPHER_free.argtypes = [ctypes.c_void_p]
if crypto.OSSL_PROVIDER_set_default_search_path(None, os.fsencode(appdir / 'usr/lib/ossl-modules')) != 1:
    raise SystemExit('Cannot select the bundled OpenSSL module directory')
providers = [crypto.OSSL_PROVIDER_load(None, name) for name in (b'default', b'legacy')]
digest = crypto.EVP_MD_fetch(None, b'MD4', None)
cipher = crypto.EVP_CIPHER_fetch(None, b'RC4', None)
if not all(providers) or not digest or not cipher:
    raise SystemExit('Bundled NLA/NTLM algorithms are unavailable')
crypto.EVP_MD_free(digest)
crypto.EVP_CIPHER_free(cipher)
versions = set()
elf_files = {}
for path in sorted(appdir.rglob('*')):
    if not path.is_file():
        continue
    with path.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            continue
    if not path.resolve().is_relative_to(appdir):
        raise SystemExit(f'ELF symlink escapes the AppDir: {path}')
    result = subprocess.check_output(['readelf', '--version-info', str(path)], text=True)
    required = {tuple(map(int, v.split('.'))) for v in re.findall(r'\bGLIBC_([0-9.]+)\b', result)}
    if required and max(required) > (2, 35):
        raise SystemExit(f'{path.name} needs GLIBC_{".".join(map(str, max(required)))}; build in Ubuntu 22.04')
    versions.update(required)
    dynamic = subprocess.check_output(['readelf', '--dynamic', str(path)], text=True)
    for line in dynamic.splitlines():
        if ('RPATH' in line or 'RUNPATH' in line) and re.search(r'\[(?:/|[^\]]*:/)', line):
            raise SystemExit(f'Nonportable absolute RPATH: {path.name}: {line.strip()}')
    elf_files[str(path.relative_to(appdir))] = hashlib.sha256(path.read_bytes()).hexdigest()
for forbidden in ('libc.so.6', 'ld-linux-x86-64.so.2'):
    if list(appdir.rglob(forbidden)):
        raise SystemExit(f'Do not bundle the host C library/loader: {forbidden}')
metadata = {
    'source_commit': os.environ.get('LRDP_SOURCE_COMMIT', ''),
    'native_abi': 5,
    'architecture': 'x86_64',
    'maximum_glibc_requirement': '.'.join(map(str, max(versions))),
    'tools': tools,
    'elf_sha256': elf_files,
    'openssl_legacy_algorithms_checked': ['MD4', 'RC4'],
    'scope': 'Packaging/ABI checks; actual UI and RDP execution require separate acceptance',
}
(appdir / 'usr/share/doc/lrdp/APPIMAGE_BUILD.json').write_text(json.dumps(metadata, indent=2) + '\n')
for provider in reversed(providers):
    crypto.OSSL_PROVIDER_unload(provider)
print(f'PASS: {len(elf_files)} ELF files, native ABI 5, GLIBC <= 2.35, relative runtime paths')
