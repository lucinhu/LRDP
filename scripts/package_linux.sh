#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_version="$(sed -n 's/^version: \([^+]*\).*/\1/p' "$project_root/pubspec.yaml")"
bundle="$project_root/build/linux/x64/release/bundle"
[[ -x "$bundle/lrdp" && -f "$bundle/lib/liblrdp.so" ]] || {
  echo 'Run flutter build linux --release first.' >&2; exit 1;
}
# Startup alone does not load the RDP bridge. Refuse stale libraries/AOT or an
# integration entrypoint before producing a user-facing archive.
python3 - "$project_root" "$bundle" <<'PY_CHECK'
from pathlib import Path
import ctypes
import hashlib
import json
import sys
root, bundle = map(Path, sys.argv[1:])
config = (root / 'linux/flutter/ephemeral/generated_config.cmake').read_text()
if 'FLUTTER_TARGET=lib/main.dart' not in config:
    raise SystemExit('Run a release build explicitly targeting lib/main.dart first')
bridge = ctypes.CDLL(str(bundle / 'lib/liblrdp.so'))
try:
    abi = bridge.lrdp_abi_version()
except AttributeError:
    raise SystemExit('Stale installed native bridge: ABI version export is missing')
if abi != 5:
    raise SystemExit(f'Unexpected bridge ABI {abi}; rebuild the release bundle')
report = json.loads((root / 'build/input-stop-runtime/native-custom/VERDICT.json').read_text())
if (report.get('passed') is not True or report.get('native_abi') != 5 or
        report.get('library_sha256') != hashlib.sha256((bundle / 'lib/liblrdp.so').read_bytes()).hexdigest()):
    raise SystemExit('Run the installed library input-release and blocked-cancellation regression first')
plugin = bundle / 'lib/liblrdp_native_plugin.so'
if not plugin.is_file() or not all(hasattr(bridge, name) for name in (
        'lrdp_video_ticket', 'lrdp_video_open', 'lrdp_video_info', 'lrdp_video_visit', 'lrdp_video_close')):
    raise SystemExit('Rebuild the Linux native texture plugin and its matching bridge')
for target, groups in ((bundle / 'lib/liblrdp.so', ('native/src', 'native/include')),
        (plugin, ('native/include', 'packages/lrdp_native/linux'))):
    inputs = [path for group in groups for path in (root / group).rglob('*') if path.is_file()]
    # Android's renderer is conditionally excluded from Linux by native/CMakeLists.txt.
    inputs = [path for path in inputs if path != root / 'native/src/android_video.c']
    if inputs and target.stat().st_mtime < max(path.stat().st_mtime for path in inputs):
        raise SystemExit('Installed native plugin/core predates source files; rebuild/install first')
aot = bundle / 'lib/libapp.so'
inputs = [*root.glob('lib/**/*.dart'), root / 'pubspec.yaml']
if not aot.exists() or aot.stat().st_mtime < max(path.stat().st_mtime for path in inputs):
    raise SystemExit('Installed Dart AOT predates application sources; rebuild/install first')
mouse = json.loads((root / 'build/linux-mouse-runtime/VERDICT.json').read_text())
if (mouse.get('passed') is not True or mouse.get('entrypoint') != 'lib/main.dart Linux Release' or
        mouse.get('library_sha256') != hashlib.sha256((bundle / 'lib/liblrdp.so').read_bytes()).hexdigest() or
        mouse.get('aot_sha256') != hashlib.sha256(aot.read_bytes()).hexdigest() or
        mouse.get('plugin_sha256') != hashlib.sha256(plugin.read_bytes()).hexdigest()):
    raise SystemExit('Run the actual main Release OS mouse regression against this bundle first')
print('PASS: release main entry, native texture plugin, ABI v5, current Dart AOT and OS mouse regression')
PY_CHECK
package_name="lrdp-$app_version-linux-x64"
output="${LRDP_DISTRIBUTIONS_DIR:-$project_root/build/distributions}"
mkdir -p "$output"
staging="$(mktemp -d "$project_root/build/package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/$package_name"
cp -a "$bundle/." "$staging/$package_name/"
cp "$project_root/LICENSE" "$project_root/NOTICE" "$staging/$package_name/"
cp -a "$project_root/docs" "$staging/$package_name/"
cat > "$staging/$package_name/README-LINUX.txt" <<'HELP'
LRDP 0.1 development preview

Extract the entire archive, enter this directory, and run ./lrdp.
Keep the lib and data directories next to the executable.
To add LRDP and its icon to your application menu, run ./install-desktop.sh.
This registers the current bundle location for your user; keep it at that path.

Built and tested on Arch Linux x86_64. This archive uses the system GTK 3,
OpenSSL 3, libsecret, libpulse, libepoxy and EGL/OpenGL runtimes. Other distributions have not been verified;
use a source build on your target distribution when the runtime ABI differs.
An unlocked Secret Service is required to remember passwords.

See docs/USAGE.md for Chinese input and bidirectional file transfer.
See docs/VERIFICATION.md for the exact tests and remaining limitations.

FreeRDP 3.32.2 is statically linked into lib/liblrdp.so. No external RDP client
or system FreeRDP package is required. The upstream source is unmodified.
The minimal FFmpeg H.264 decoder is statically linked (LGPL-2.1-or-later).
Keep the matching LRDP source/rebuild kit with this archive for redistribution.
It contains the exact FFmpeg sources and the full application for relinking.
HELP
tar -czf "$staging/$package_name.tar.gz" -C "$staging" "$package_name"
mv "$staging/$package_name.tar.gz" "$output/"
(cd "$output" && sha256sum "$package_name.tar.gz" > "$package_name.tar.gz.sha256")
printf '%s\n' "$output/$package_name.tar.gz"
