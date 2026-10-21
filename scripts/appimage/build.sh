#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$task_root"
# Run inside the image defined by Containerfile, with the SDK mounted at /opt/flutter.
export PATH="/opt/flutter/bin:$PATH"
export LRDP_BUILD_JOBS="${LRDP_BUILD_JOBS:-4}"
export LRDP_FFMPEG_ROOT="$task_root/build/deps/ffmpeg/linux-x64"
bash scripts/build_ffmpeg.sh linux-x64
flutter pub get --offline
flutter build linux --no-pub --release --target lib/main.dart
bash scripts/package_appimage.sh
