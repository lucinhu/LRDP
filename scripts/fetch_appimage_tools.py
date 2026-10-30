#!/usr/bin/env python3
"""Fetch reviewed AppImage tools into the ignored build cache."""
from pathlib import Path
import hashlib
import json
import os
import urllib.request

root = Path(__file__).resolve().parent.parent
output = root / 'build/deps/appimage'
output.mkdir(parents=True, exist_ok=True)
# Pinned to immutable versioned releases rather than the mutable
# "continuous" tags: the continuous assets are rebuilt in place, so a hash
# pinned once starts failing on the next upstream rebuild (that is exactly
# what broke the first 0.3.0 release run). Versioned assets cannot move, so
# the pins stay auditable: url + tag commit + sha256 all identify one file.
tools = {
    'appimagetool-x86_64.AppImage': {
        'url': 'https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage',
        'sha256': 'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0',
        'commit': '8c8c91f762b412a19f4e8d2c4b35afb98f2d7c81',
    },
    'linuxdeploy-x86_64.AppImage': {
        'url': 'https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage',
        'sha256': 'c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d',
        'commit': 'cc7b86472c3caa3fd729b9dc502fd2aa78394257',
    },
    'runtime-x86_64': {
        'url': 'https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64',
        'sha256': '2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d',
        'commit': 'dd6cebedcbddde9c82f89b011e8e1d40b6e43868',
    },
    'linuxdeploy-plugin-gtk.sh': {
        'url': 'https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5075073ff8790f26effbac5f84453/linuxdeploy-plugin-gtk.sh',
        'sha256': 'b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171',
        'commit': '7a3fbc31a9e5075073ff8790f26effbac5f84453',
    },
}
for name, info in tools.items():
    path = output / name
    if not path.exists():
        temporary = output / (name + '.download')
        request = urllib.request.Request(info['url'], headers={'User-Agent': 'LRDP-AppImage-builder'})
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open('wb') as stream:
            while chunk := response.read(1024 * 1024):
                stream.write(chunk)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != info['sha256']:
            temporary.unlink()
            raise SystemExit(f'Unreviewed download: {name}; audit tool updates before changing the pin')
        os.replace(temporary, path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != info['sha256']:
        raise SystemExit(f'Cached tool hash mismatch: {name}')
    path.chmod(0o755)
(output / 'TOOLS.json').write_text(json.dumps(tools, indent=2) + '\n')
print(output)
