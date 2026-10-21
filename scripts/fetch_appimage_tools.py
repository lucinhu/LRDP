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
tools = {
    'appimagetool-x86_64.AppImage': {
        'url': 'https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage',
        'sha256': '95cbe7cce9717fce90c484e34052ee7c7f1d7635b33c12525b4776826a7d29b6',
        'commit': '854e19e951900cf141245b384d45735942521abe',
    },
    'linuxdeploy-x86_64.AppImage': {
        'url': 'https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage',
        'sha256': '8aea8da0f7f7039d2a2cecb14657d752a222a5e1d3825caeef186c82f751cdd1',
        'commit': '07333c6e942c7d71782b66be924c5d867f9dfdfc',
    },
    'runtime-x86_64': {
        'url': 'https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64',
        'sha256': '617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46',
        'commit': 'fedfad51acc2860b2916a1eef32ba4a500ff31ef',
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
