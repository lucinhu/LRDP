#!/usr/bin/env python3
"""Build in an independent Ubuntu 22.04 tree using a private rootless Podman store."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import uuid

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--flutter-sdk', type=Path, required=True)
parser.add_argument('--pub-cache', type=Path, default=Path(os.environ.get('PUB_CACHE', Path.home() / '.pub-cache')))
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
sdk, pub_cache, output = (p.resolve() for p in (args.flutter_sdk, args.pub_cache, args.output))
if not (sdk / 'bin/flutter').is_file() or not pub_cache.is_dir():
    parser.error('A populated Flutter SDK and Pub cache are required; run flutter pub get first')
if list(output.glob('*.AppImage')):
    parser.error('Choose a fresh output directory; finalized AppImages are never overwritten')
upstream = root / 'third_party/FreeRDP'
if subprocess.check_output(['git', '-C', str(upstream), 'status', '--porcelain']):
    raise SystemExit('FreeRDP must remain unmodified')
subprocess.run(['python3', str(root / 'scripts/fetch_appimage_tools.py')], check=True)
subprocess.run(['bash', str(root / 'scripts/fetch_ffmpeg.sh')], check=True)
work = root / 'build/appimage-work'
work.mkdir(parents=True, exist_ok=True)
store = root / 'build/appimage-containers'
podman = ['podman', '--root', str(store / 'storage'), '--runroot', str(store / 'run'), '--storage-driver', 'vfs']
image = 'localhost/lrdp-appimage:ubuntu22.04'
containerfile = (root / 'scripts/appimage/Containerfile').read_text()
container_hash = hashlib.sha256(containerfile.encode()).hexdigest()
image_metadata = work / 'toolchain-info.json'
cached = json.loads(image_metadata.read_text()) if image_metadata.exists() else {}
inspect = subprocess.run([*podman, 'image', 'inspect', image, '--format', '{{.Id}}'], capture_output=True, text=True)
if (inspect.returncode or cached.get('containerfile_sha256') != container_hash or
        cached.get('image_id') != inspect.stdout.strip()):
    # run+commit also works on hosts where buildah's overlay build-context mount is unavailable.
    if containerfile.count('\nRUN ') != 1:
        raise SystemExit('Review this helper before adding more Containerfile build steps')
    base = containerfile.splitlines()[0].removeprefix('FROM ').strip()
    install = containerfile.split('\nRUN ', 1)[1].split('\n\n', 1)[0].replace('\\\n', '')
    name = 'lrdp-appimage-builder-' + uuid.uuid4().hex[:12]
    subprocess.run([*podman, 'pull', base], check=True)
    try:
        subprocess.run([*podman, 'run', '--name', name, '--network=host',
                        '--env', 'DEBIAN_FRONTEND=noninteractive', base, '/bin/sh', '-c', install], check=True)
        subprocess.run([*podman, 'commit', '--change', 'WORKDIR /project', name, image], check=True)
    finally:
        subprocess.run([*podman, 'rm', '--force', name], check=False)
    image_id = subprocess.check_output([*podman, 'image', 'inspect', image, '--format', '{{.Id}}'], text=True).strip()
    cached = {'containerfile_sha256': container_hash, 'image_id': image_id, 'base_image': base}
    image_metadata.write_text(json.dumps(cached, indent=2) + '\n')

source = work / 'source'
source.mkdir(exist_ok=True)
paths = [p.decode() for p in subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).split(b'\0') if p]
inputs = {path: root / path for path in paths if path != 'third_party/FreeRDP'}
inputs.update({'third_party/FreeRDP/' + p.decode(): upstream / p.decode()
               for p in subprocess.check_output(['git', '-C', str(upstream), 'ls-files', '-z']).split(b'\0') if p})
inventory = work / 'source-inventory.json'
previous = json.loads(inventory.read_text()) if inventory.exists() else []
for stale in set(previous) - inputs.keys():
    (source / stale).unlink(missing_ok=True)
fingerprint = hashlib.sha256(b'LRDP-AppImage-inputs-v1\0')
for relative, original in sorted(inputs.items()):
    target = source / relative
    content = original.read_bytes()
    fingerprint.update(relative.encode() + b'\0' + hashlib.sha256(content).digest())
    if not target.exists() or target.read_bytes() != content:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target)
inventory.write_text(json.dumps(sorted(inputs), indent=2) + '\n')
for relative in ('appimage', 'downloads'):
    target = source / 'build/deps' / relative
    target.mkdir(parents=True, exist_ok=True)
    candidates = (root / 'build/deps/appimage').iterdir() if relative == 'appimage' else [root / 'build/deps/downloads/ffmpeg-9.0.2.tar.xz']
    for original in candidates:
        if original.is_file():
            shutil.copy2(original, target / original.name)
output.mkdir(parents=True, exist_ok=True)
commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
subprocess.run([*podman, 'run', '--rm', '--network=host',
                '--volume', f'{source}:/project:rw', '--volume', f'{sdk}:/opt/flutter:rw',
                '--volume', f'{pub_cache}:{pub_cache}:rw', '--volume', f'{output}:/output:rw',
                '--env', 'PUB_CACHE=' + str(pub_cache), '--env', 'CI=true',
                '--env', 'GIT_CONFIG_COUNT=1', '--env', 'GIT_CONFIG_KEY_0=safe.directory',
                '--env', 'GIT_CONFIG_VALUE_0=/opt/flutter',
                '--env', 'LRDP_BUILD_JOBS=' + os.environ.get('LRDP_BUILD_JOBS', '4'),
                '--env', 'LRDP_DISTRIBUTIONS_DIR=/output', '--env', 'LRDP_SOURCE_COMMIT=' + commit,
                image, 'bash', 'scripts/appimage/build.sh'], check=True)
(output / 'CONTAINER_BUILD.json').write_text(json.dumps({**cached, 'source_commit': commit,
    'source_inputs_sha256': fingerprint.hexdigest(), 'source_files': len(inputs)}, indent=2) + '\n')
print(output)
