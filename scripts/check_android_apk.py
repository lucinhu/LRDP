#!/usr/bin/env python3
"""Verify Android ABIs, ELF/RELRO safety, ZIP alignment, signature and entrypoint."""
from pathlib import Path
import argparse
import os
import struct
import subprocess
import zipfile


def elf_headers(data):
    if data[:4] != b'\x7fELF' or data[5] != 1 or data[4] not in (1, 2):
        raise ValueError('Expected little-endian Android ELF')
    bits = 64 if data[4] == 2 else 32
    machine = struct.unpack_from('<H', data, 18)[0]
    if bits == 64:
        offset = struct.unpack_from('<Q', data, 32)[0]
        size, count = struct.unpack_from('<HH', data, 54)
    else:
        offset = struct.unpack_from('<I', data, 28)[0]
        size, count = struct.unpack_from('<HH', data, 42)
    headers = []
    for index in range(count):
        start = offset + index * size
        if bits == 64:
            kind, flags, file_offset, virtual, _, file_size, memory, alignment = struct.unpack_from('<IIQQQQQQ', data, start)
        else:
            kind, file_offset, virtual, _, file_size, memory, flags, alignment = struct.unpack_from('<IIIIIIII', data, start)
        headers.append({'type': kind, 'flags': flags, 'start': virtual, 'end': virtual + memory,
                        'offset': file_offset, 'file_size': file_size, 'align': alignment})
    return bits, machine, headers


def verify_segments(headers, page=16384):
    loads = [h for h in headers if h['type'] == 1]
    if not loads:
        raise ValueError('ELF has no LOAD segments')
    for h in loads:
        if h['align'] < page or (h['start'] - h['offset']) % page:
            raise ValueError('LOAD segment is not page aligned')
    for relro in (h for h in headers if h['type'] == 0x6474e552):
        low = relro['start'] // page * page
        high = (relro['end'] + page - 1) // page * page
        # LLD may include trailing zero padding in RELRO.p_memsz beyond the
        # containing LOAD.p_memsz (for example AndroidX datastore's counter).
        if not any(h['start'] <= relro['start'] < h['end'] and
                   relro['end'] <= (h['end'] + page - 1) // page * page for h in loads):
            raise ValueError('RELRO is outside LOAD segments')
        for h in loads:
            if not h['flags'] & 2:
                continue
            # A RELRO-only LOAD may end inside a page if the next writable LOAD
            # starts on a separate page. Reject actual writable-byte overlap,
            # rather than rejecting safe NDK/Flutter RELRO padding layouts.
            for begin, end in ((h['start'], min(h['end'], relro['start'])),
                               (max(h['start'], relro['end']), h['end'])):
                if max(begin, low) < min(end, high):
                    raise ValueError('RELRO page protection overlaps writable data')


def verify_entrypoint(archive, abis, integration=False, release=False):
    names = archive.namelist()
    kernel = 'assets/flutter_assets/kernel_blob.bin'
    if release and kernel in names:
        raise ValueError('Release APK contains a Dart debug kernel')
    if kernel in names:
        data = archive.read(kernel)
    else:
        apps = [f'lib/{abi}/libapp.so' for abi in abis]
        if not all(name in names for name in apps):
            raise ValueError('APK has neither a Dart kernel nor all AOT applications')
        data = b'\0'.join(archive.read(name) for name in apps)
        if not integration and any(b'package:lrdp/main.dart' not in archive.read(name) for name in apps):
            raise ValueError('AOT application does not identify the LRDP production entrypoint')
    if not integration and (b'package:lrdp/main.dart' not in data or
                            b'integration_test/' in data or b'package:integration_test/' in data):
        raise ValueError('APK does not use the LRDP production entrypoint')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--abi', action='append', required=True)
    parser.add_argument('--integration', action='store_true', help='Allow an integration-test Dart entrypoint')
    parser.add_argument('--build-mode', choices=['debug', 'release'])
    parser.add_argument('--sdk-root', type=Path, default=Path(os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'Android/Sdk'))))
    args = parser.parse_args()
    machines = {'arm64-v8a': 183, 'x86_64': 62, 'armeabi-v7a': 40}
    with zipfile.ZipFile(args.apk) as archive:
        libraries = [n for n in archive.namelist() if n.startswith('lib/') and n.endswith('.so')]
        actual = {name.split('/')[1] for name in libraries}
        if actual != set(args.abi):
            raise ValueError(f'Unexpected ABI set: {actual}')
        for abi in actual:
            if f'lib/{abi}/liblrdp.so' not in libraries:
                raise ValueError(f'Missing LRDP native bridge for {abi}')
        for name in libraries:
            abi = name.split('/')[1]
            bits, machine, headers = elf_headers(archive.read(name))
            if machine != machines[abi] or bits != (32 if abi == 'armeabi-v7a' else 64):
                raise ValueError(f'ELF architecture does not match {name}')
            verify_segments(headers, page=4096 if bits == 32 else 16384)
            print(f'PASS: {name} LOAD and RELRO')
        verify_entrypoint(archive, actual, integration=args.integration, release=args.build_mode == 'release')
    kit = args.sdk_root / 'build-tools/36.0.0'
    env = dict(os.environ)
    java = Path('/usr/lib/jvm/java-17-openjdk')
    if java.exists():
        env['JAVA_HOME'] = str(java)
        env['PATH'] = str(java / 'bin') + ':' + env['PATH']
    if args.build_mode:
        manifest = subprocess.check_output([str(kit / 'aapt2'), 'dump', 'badging', str(args.apk)],
                                          env=env, text=True)
        debuggable = 'application-debuggable' in manifest
        if debuggable != (args.build_mode == 'debug'):
            raise ValueError(f'APK debuggability does not match {args.build_mode}')
    subprocess.run([str(kit / 'zipalign'), '-c', '-P', '16', '4', str(args.apk)], check=True, env=env)
    result = subprocess.run([str(kit / 'apksigner'), 'verify', '--verbose', str(args.apk)],
                            check=True, text=True, capture_output=True, env=env)
    if 'v2): true' not in result.stdout and 'v3): true' not in result.stdout:
        raise ValueError('APK needs a modern signature scheme')
    print('PASS: APK ABI set, ELF/RELRO, ZIP page alignment, signature and entrypoint policy')


if __name__ == '__main__':
    main()
