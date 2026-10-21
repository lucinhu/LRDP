#!/usr/bin/env python3
"""Package application/upstream sources and the exact static FFmpeg sources.

Only Git-listed, non-ignored application files and tracked FreeRDP files enter
the archive. Runtime logs, credentials, screenshots and builds stay outside it.
"""
from pathlib import Path
import hashlib
import io
import json
import os
import re
import subprocess
import tarfile

root = Path(__file__).resolve().parent.parent
upstream = root / 'third_party/FreeRDP'


def git(directory, *args):
    return subprocess.check_output(['git', '-C', str(directory), *args])


if git(upstream, 'status', '--porcelain'):
    raise SystemExit('FreeRDP must remain unmodified')
commit = git(upstream, 'rev-parse', 'HEAD').decode().strip()
paths = sorted(set(git(root, 'ls-files', '--cached', '--others',
    '--exclude-standard', '-z').split(b'\0')) - {b''})
fingerprint = hashlib.sha256(b'LRDP-source-v1\0')
for raw in paths:
    content = commit.encode() if raw == b'third_party/FreeRDP' else (root / raw.decode()).read_bytes()
    fingerprint.update(raw + b'\0' + hashlib.sha256(content).digest() + b'\0')
version = re.search(r'^version:\s*([^+\s]+)', (root / 'pubspec.yaml').read_text(), re.M).group(1)
name = f'lrdp-{version}-source'
output = Path(os.environ.get('LRDP_DISTRIBUTIONS_DIR', root / 'build/distributions')).resolve()
output.mkdir(parents=True, exist_ok=True)
destination = output / (name + '.tar.gz')
ffmpeg = root / 'build/deps/downloads/ffmpeg-9.0.2.tar.xz'
ffmpeg_sha = '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
if hashlib.sha256(ffmpeg.read_bytes()).hexdigest() != ffmpeg_sha:
    raise SystemExit('Run scripts/fetch_ffmpeg.sh to obtain the exact FFmpeg sources')
metadata = {'source_sha256': fingerprint.hexdigest(), 'source_files': len(paths),
    'native_abi': 5, 'freerdp_commit': commit, 'freerdp_source_modified': False,
    'ffmpeg_version': '9.0.2', 'ffmpeg_sha256': ffmpeg_sha,
    'ffmpeg_license': 'LGPL-2.1-or-later', 'ffmpeg_sources': 'vendor/ffmpeg-9.0.2.tar.xz'}
readme = '''LRDP development source and rebuild kit

Application sources and the unmodified FreeRDP submodule snapshot are already
expanded. No Git metadata is included; skip `git submodule update` in this kit.
Extract outside another Git checkout so upstream's version detection cannot
accidentally pick up an unrelated parent repository.
For ongoing upstream updates use the original Git repository and its submodule.

For an offline FFmpeg source fetch, from this directory:
  mkdir -p build/deps/downloads
  cp vendor/ffmpeg-9.0.2.tar.xz build/deps/downloads/
  bash scripts/build_ffmpeg.sh linux-x64
  export LRDP_FFMPEG_ROOT="$PWD/build/deps/ffmpeg/linux-x64"

See docs/BUILDING.md for Flutter, OpenSSL and each platform toolchain. The build
scripts compile static H.264 decoding only, without GPL/nonfree components.
All LRDP application/adaptor source is included, so rebuild/relink the full
application with a modified LGPL FFmpeg using the same public interfaces.
Keep the licenses, NOTICE and this corresponding source kit with redistribution.
FFmpeg license text is in assets/licenses/FFmpeg.txt and its source archive.
The FFmpeg configure options and static-archive hashes for the delivered builds
are under build-config/ffmpeg/. No signing keys are included; use your own key.

BUILD_INFO-SOURCE.json identifies the source snapshot. Package verification
scripts require Git metadata; they are not required for building/running here.
'''
with tarfile.open(destination, 'w:gz', compresslevel=6) as archive:
    for raw in paths:
        path = raw.decode()
        if path == 'third_party/FreeRDP':
            for entry in git(upstream, 'ls-files', '-z').split(b'\0'):
                if entry:
                    relative = entry.decode()
                    archive.add(upstream / relative,
                        arcname=f'{name}/{path}/{relative}', recursive=False)
        else:
            archive.add(root / path, arcname=f'{name}/{path}', recursive=False)
    archive.add(ffmpeg, arcname=f'{name}/vendor/{ffmpeg.name}')
    for platform in ('linux-x64', 'windows-x64', 'android/arm64-v8a', 'android/x86_64'):
        for filename in ('BUILD_INFO.json', 'configure-options.txt', 'LICENSE-FFmpeg.txt'):
            path = root / 'build/deps/ffmpeg' / platform / filename
            archive.add(path, arcname=f'{name}/build-config/ffmpeg/{platform}/{filename}')
    appimage_ffmpeg = root / 'build/appimage-work/source/build/deps/ffmpeg/linux-x64'
    if appimage_ffmpeg.is_dir():
        for filename in ('BUILD_INFO.json', 'configure-options.txt', 'LICENSE-FFmpeg.txt'):
            archive.add(appimage_ffmpeg / filename,
                arcname=f'{name}/build-config/ffmpeg/appimage-linux-x64/{filename}')
    for filename, content in (('README-SOURCE.txt', readme),
            ('BUILD_INFO-SOURCE.json', json.dumps(metadata, indent=2) + '\n')):
        data = content.encode()
        entry = tarfile.TarInfo(f'{name}/{filename}')
        entry.size = len(data)
        entry.mode = 0o644
        archive.addfile(entry, io.BytesIO(data))
checksum = hashlib.file_digest(destination.open('rb'), 'sha256').hexdigest()
(output / (destination.name + '.sha256')).write_text(f'{checksum}  {destination.name}\n')
print(destination)
