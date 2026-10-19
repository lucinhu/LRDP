#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_version=9.0.2
# Official tarball; its detached signature was verified using the release key
# FCF986EA15E6E293A5644F10B4322F04D67658D8 before pinning this digest.
task_sha=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
task_archive="$task_root/build/deps/downloads/ffmpeg-$task_version.tar.xz"
task_source="$task_root/build/deps/sources/ffmpeg-$task_version"
mkdir -p "$(dirname "$task_archive")" "$(dirname "$task_source")"
if [[ ! -f "$task_archive" ]]; then
  curl --fail --location --retry 2 "https://ffmpeg.org/releases/ffmpeg-$task_version.tar.xz" -o "$task_archive.tmp"
  mv "$task_archive.tmp" "$task_archive"
fi
printf '%s  %s\n' "$task_sha" "$task_archive" | sha256sum --check >&2
if [[ ! -f "$task_source/configure" ]]; then
  tar -xJf "$task_archive" -C "$(dirname "$task_source")"
fi
printf '%s\n' "$task_source"
