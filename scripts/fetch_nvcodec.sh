#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
# FFmpeg 9 accepts SDK 12.1 headers; newer SDK headers need newer drivers.
# Official FFmpeg nv-codec-headers release archive, downloaded over HTTPS.
task_version=12.1.14.0
task_sha=62b30ab37e4e9be0d0c5b37b8fee4b094e38e570984d56e1135a6b6c2c164c9f
task_url="https://github.com/FFmpeg/nv-codec-headers/releases/download/n$task_version/nv-codec-headers-$task_version.tar.gz"
task_archive="$task_root/build/deps/downloads/nv-codec-headers-$task_version.tar.gz"
task_source="$task_root/build/deps/sources/nv-codec-headers-$task_version"
task_prefix="$task_root/build/deps/nv-codec-headers/$task_version"
mkdir -p "$(dirname "$task_archive")" "$(dirname "$task_source")" "$task_prefix"
if [[ ! -f "$task_archive" ]]; then
  curl --fail --location --retry 2 "$task_url" -o "$task_archive.tmp"
  mv "$task_archive.tmp" "$task_archive"
fi
printf '%s  %s\n' "$task_sha" "$task_archive" | sha256sum --check >&2
if [[ ! -f "$task_source/Makefile" ]]; then
  tar -xzf "$task_archive" -C "$(dirname "$task_source")"
fi
# Header-only install. Never write to the host's /usr or /usr/local prefix.
make -C "$task_source" PREFIX="$task_prefix" LIBDIR=lib install >&2
python3 - "$task_prefix" "$task_version" "$task_url" "$task_sha" <<'PY'
from pathlib import Path
import json,sys
prefix=Path(sys.argv[1])
(prefix/'BUILD_INFO.json').write_text(json.dumps({
    'version':sys.argv[2], 'source_url':sys.argv[3], 'source_sha256':sys.argv[4],
    'license':'MIT', 'header_only':True,
    'minimum_linux_driver':'530.41.03',
},indent=2)+'\n')
PY
printf '%s\n' "$task_prefix"
