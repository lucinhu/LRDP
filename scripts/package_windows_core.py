#!/usr/bin/env python3
"""Package the verified MinGW Windows C ABI core development bundle."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import zipfile

root = Path(__file__).resolve().parent.parent
binary = root / 'build/windows-x64/lrdp.dll'
with binary.open('rb') as stream:
    checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
report = json.loads((root / 'build/windows-runtime/winpr/VERDICT.json').read_text())
if report.get('result') != 'passed' or report.get('sspi_provider') != 'winpr':
    raise SystemExit('Run the explicit WinPR/Wine protocol regression first')
if report.get('core_sha256') != checksum:
    raise SystemExit('The DLL changed after verification; rerun the protocol regression')
cursor_report = json.loads((root / 'build/cursor-runtime/wine/VERDICT.json').read_text())
if (cursor_report.get('result') != 'passed' or cursor_report.get('abi') != 5 or
        cursor_report.get('core_sha256') != checksum):
    raise SystemExit('Run the current DLL cursor protocol regression first')
paste_report = json.loads((root / 'build/paste-runtime/wine/VERDICT.json').read_text())
if (paste_report.get('passed') is not True or paste_report.get('abi') != 5 or
        paste_report.get('library_sha256') != checksum):
    raise SystemExit('Run the current DLL paste protocol regression first')
audio_report = json.loads((root / 'build/audio-runtime/wine/VERDICT.json').read_text())
if (audio_report.get('passed') is not True or audio_report.get('native_abi') != 5 or
        audio_report.get('library_sha256') != checksum):
    raise SystemExit('Run the current DLL actual audio playback regression first')
input_stop_report = json.loads((root / 'build/input-stop-runtime/wine/VERDICT.json').read_text())
if (input_stop_report.get('passed') is not True or input_stop_report.get('native_abi') != 5 or
        input_stop_report.get('library_sha256') != checksum):
    raise SystemExit('Run the current DLL actual input-release and blocked-cancellation regression first')
description = subprocess.check_output(['x86_64-w64-mingw32-objdump', '-p', str(binary)], text=True)
if 'file format pei-x86-64' not in description:
    raise SystemExit('Expected Windows x64 PE binary')
symbols = set(re.findall(r'\b(lrdp_\w+)\s*\(', (root / 'native/include/lrdp.h').read_text()))
exported = set(re.findall(r'\b(lrdp_\w+)\b', description))
if not symbols.issubset(exported):
    raise SystemExit('Missing LRDP C ABI exports: ' + ', '.join(sorted(symbols - exported)))
imports = re.findall(r'DLL Name: (\S+)', description)
external = ('libgcc', 'libwinpthread', 'libssl', 'libcrypto', 'freerdp', 'libfreerdp', 'winpr', 'libwinpr')
if any(name.lower().startswith(external) for name in imports):
    raise SystemExit('Unbundled dependency; inspect the Windows PE imports')
if subprocess.check_output(['git', '-C', str(root / 'third_party/FreeRDP'), 'status', '--porcelain']):
    raise SystemExit('FreeRDP source must remain unmodified')
commit = subprocess.check_output(['git', '-C', str(root / 'third_party/FreeRDP'), 'rev-parse', 'HEAD'], text=True).strip()
version = re.search(r'^version:\s*([^+\s]+)', (root / 'pubspec.yaml').read_text(), re.M).group(1)
name = f'lrdp-{version}-windows-x64-core-debug'
output = root / 'build/distributions'
output.mkdir(parents=True, exist_ok=True)
destination = output / (name + '.zip')
fingerprint = hashlib.sha256(b'LRDP-source-v1\0')
paths = sorted(set(subprocess.check_output(['git', '-C', str(root), 'ls-files',
    '--cached', '--others', '--exclude-standard', '-z']).split(b'\0')) - {b''})
for raw in paths:
    content = commit.encode() if raw == b'third_party/FreeRDP' else (root / raw.decode()).read_bytes()
    fingerprint.update(raw + b'\0' + hashlib.sha256(content).digest() + b'\0')
source_sha = fingerprint.hexdigest()
metadata = {'abi': 5, 'version': version, 'core_sha256': checksum, 'source_sha256': source_sha,
    'input_stop_verification': input_stop_report,
    'paste_verification': paste_report,
    'audio_verification': audio_report,
    'cursor_verification': cursor_report, 'freerdp_commit': commit, 'freerdp_source_modified': False, 'imports': imports,
    'exports': sorted(symbols), 'wine_verification': report, 'flutter_runner': False,
    'native_system_sspi': 'Not verified on real Windows; an earlier Wine 11.20 build returned SEC_E_INVALID_TOKEN'}
system_report = root / 'build/windows-runtime/system/RESULT.json'
if system_report.exists():
    system = json.loads(system_report.read_text())
    if system.get('core_sha256') == checksum:
        metadata['wine_system_sspi_result'] = system
readme = '''LRDP Windows x64 core development build

This bundle contains lrdp.dll and the UTF-8 C ABI v5 in include/lrdp.h.
Use matching Dart bindings; the cursor protocol was verified against this DLL.
Build the complete Flutter Windows app from the repository with Visual Studio
and static OpenSSL, following docs/BUILDING.md.

The PE DLL was built with MinGW and exercised under Wine, with fixed-pin TLS,
actual server graphics and keyboard/mouse events, NLA through WinPR SSPI,
1 MiB bidirectional RDPDR files and Chinese directory/names/input.
WinMM playback was captured through Wine's Pulse driver into a private null
sink, with stereo PCM tone verification, mute and unsupported-format checks.

The normal Windows application still uses operating-system SSPI by default.
An earlier Wine 11.20 native SSPI test returned SEC_E_INVALID_TOKEN in this fixture.
The full Flutter runner, actual Windows SSPI and physical Windows interaction
remain unverified. See BUILD_INFO.json and the included verification record.

Keep third-party notices and the matching LRDP source/rebuild kit with the DLL.
The kit includes the exact LGPL FFmpeg sources and the full app for relinking.
FreeRDP/WinPR, the minimal FFmpeg H.264 decoder and OpenSSL are statically
linked; the PE import list and public C ABI exports are in BUILD_INFO.json.
'''
with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for path, target in [(binary, 'lrdp.dll'), (root / 'native/include/lrdp.h', 'include/lrdp.h'),
        (root / 'LICENSE', 'LICENSE'), (root / 'NOTICE', 'NOTICE'),
        (root / 'assets/licenses/FreeRDP.txt', 'licenses/FreeRDP.txt'),
        (root / 'assets/licenses/OpenSSL.txt', 'licenses/OpenSSL.txt'),
        (root / 'assets/licenses/FFmpeg.txt', 'licenses/FFmpeg.txt'),
        (root / 'docs/VERIFICATION.md', 'docs/VERIFICATION.md'),
        (root / 'docs/BUILDING.md', 'docs/BUILDING.md')]:
        archive.write(path, f'{name}/{target}')
    for path in sorted((root / 'licenses/windows').glob('*.txt')):
        archive.write(path, f'{name}/licenses/{path.name}')
    archive.writestr(f'{name}/README.txt', readme)
    archive.writestr(f'{name}/BUILD_INFO.json', json.dumps(metadata, indent=2) + '\n')
with destination.open('rb') as stream:
    package_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
(output / (destination.name + '.sha256')).write_text(f'{package_hash}  {destination.name}\n')
print(destination)
