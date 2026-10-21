#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_bundle="${LRDP_LINUX_BUNDLE:-$task_root/build/linux/x64/release/bundle}"
task_version="$(sed -n 's/^version: \([^+]*\).*/\1/p' "$task_root/pubspec.yaml")"
task_output="${LRDP_DISTRIBUTIONS_DIR:-$task_root/build/distributions}"
task_image="$task_output/lrdp-$task_version-linux-x64.AppImage"
[[ "$(uname -sm)" == 'Linux x86_64' ]] || { echo 'AppImage packaging requires Linux x86_64' >&2; exit 1; }
[[ -x "$task_bundle/lrdp" && -f "$task_bundle/lib/liblrdp.so" ]] || { echo 'Build the main Linux Release first' >&2; exit 1; }
[[ ! -e "$task_image" ]] || { echo 'Refusing to overwrite an existing AppImage; choose a new output directory' >&2; exit 1; }
python3 - "$task_root" "$task_bundle" <<'PY'
from pathlib import Path
import sys
root, bundle = map(Path, sys.argv[1:])
config = (root / 'linux/flutter/ephemeral/generated_config.cmake').read_text()
if 'FLUTTER_TARGET=lib/main.dart' not in config:
    raise SystemExit('Build --release --target lib/main.dart first')
if (bundle / 'lib/libapp.so').stat().st_mtime < max(p.stat().st_mtime for p in root.glob('lib/**/*.dart')):
    raise SystemExit('Dart AOT predates application sources; rebuild first')
PY
task_tools="$(python3 "$task_root/scripts/fetch_appimage_tools.py")"
mkdir -p "$task_output"
task_staging="$(mktemp -d "$task_root/build/appimage.XXXXXX")"
trap 'rm -rf "$task_staging"' EXIT
task_appdir="$task_staging/LRDP.AppDir"
mkdir -p "$task_appdir/usr/bin" "$task_appdir/usr/lib" "$task_appdir/usr/share/doc/lrdp"
cp "$task_bundle/lrdp" "$task_appdir/usr/bin/"
cp -a "$task_bundle/lib/." "$task_appdir/usr/lib/"
cp -a "$task_bundle/data" "$task_appdir/usr/bin/"
ln -s ../lib "$task_appdir/usr/bin/lib"
cp "$task_root/LICENSE" "$task_root/NOTICE" "$task_appdir/usr/share/doc/lrdp/"
cp -a "$task_root/docs" "$task_appdir/usr/share/doc/lrdp/"
cp "$task_root/assets/branding/lrdp-256.png" "$task_staging/dev.lrdp.lrdp.png"
cp "$task_root/linux/dev.lrdp.lrdp.desktop" "$task_staging/dev.lrdp.lrdp.desktop"
(
  cd "$task_staging"
  "$task_tools/linuxdeploy-x86_64.AppImage" --appimage-extract > /dev/null
)
mkdir -p "$task_staging/appimagetool"
(
  cd "$task_staging/appimagetool"
  "$task_tools/appimagetool-x86_64.AppImage" --appimage-extract > /dev/null
)
task_deploy="$task_staging/squashfs-root/usr/bin/linuxdeploy"
task_libraries=()
for task_library in "$task_appdir/usr/lib/"*.so; do task_libraries+=(--library "$task_library"); done
PATH="$task_tools:$PATH" DEPLOY_GTK_VERSION=3 "$task_deploy" \
  --appdir "$task_appdir" --executable "$task_appdir/usr/bin/lrdp" \
  "${task_libraries[@]}" --exclude-library 'libstdc++.so.6' --exclude-library 'libgcc_s.so.1' \
  --desktop-file "$task_staging/dev.lrdp.lrdp.desktop" \
  --icon-file "$task_staging/dev.lrdp.lrdp.png" --plugin gtk
if command -v dpkg-query > /dev/null; then
  dpkg-query -W > "$task_appdir/usr/share/doc/lrdp/BUILD_PACKAGES.txt"
  mkdir -p "$task_appdir/usr/share/doc/lrdp/dependency-copyrights"
  for task_copyright in /usr/share/doc/*/copyright; do
    [[ -f "$task_copyright" ]] || continue
    task_package="$(basename "$(dirname "$task_copyright")")"
    cp -L "$task_copyright" "$task_appdir/usr/share/doc/lrdp/dependency-copyrights/$task_package.txt"
  done
fi
python3 "$task_root/scripts/appimage/check_appdir.py" "$task_appdir" "$task_tools/TOOLS.json"
desktop-file-validate "$task_appdir/dev.lrdp.lrdp.desktop"
ARCH=x86_64 VERSION="$task_version" "$task_staging/appimagetool/squashfs-root/AppRun" \
  --runtime-file "$task_tools/runtime-x86_64" --comp zstd \
  --mksquashfs-opt -processors --mksquashfs-opt "${LRDP_BUILD_JOBS:-4}" \
  --no-appstream "$task_appdir" "$task_staging/LRDP.AppImage"
chmod +x "$task_staging/LRDP.AppImage"
mv "$task_staging/LRDP.AppImage" "$task_image"
(cd "$task_output" && sha256sum "$(basename "$task_image")" > "$(basename "$task_image").sha256")
printf '%s\n' "$task_image"
