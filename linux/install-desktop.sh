#!/usr/bin/env bash
# Register an extracted bundle for the current user without root access.
set -euo pipefail
bundle_dir="$(cd "$(dirname "$0")" && pwd)"
[[ -x "$bundle_dir/lrdp" ]] || { echo 'Keep this script in the LRDP bundle.' >&2; exit 1; }
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p "$data_dir/applications" "$data_dir/icons/hicolor/scalable/apps"
python3 - "$bundle_dir" "$data_dir" <<'PY'
from pathlib import Path
import sys
bundle, data = map(Path, sys.argv[1:])
# Desktop Exec has its own escaping rules (including percent field codes).
binary = str(bundle / 'lrdp')
if any(char in binary for char in '%=\n\r'):
    raise SystemExit('Move the bundle to a path without %, = or newlines first.')
binary = ''.join('\\' + char if char in '\\"`$' else char for char in binary)
# The desktop entry string decoder runs before the Exec quoting decoder.
binary = binary.replace('\\', '\\\\')
text = (bundle / 'share/applications/dev.lrdp.lrdp.desktop').read_text()
text = text.replace('Exec=lrdp\n', f'Exec="{binary}"\n')
(data / 'applications/dev.lrdp.lrdp.desktop').write_text(text)
(data / 'icons/hicolor/scalable/apps/dev.lrdp.lrdp.svg').write_bytes(
    (bundle / 'share/icons/hicolor/scalable/apps/dev.lrdp.lrdp.svg').read_bytes())
PY
if command -v update-desktop-database >/dev/null; then
    update-desktop-database "$data_dir/applications"
fi
printf 'LRDP added to the application menu. Keep the bundle at: %s\n' "$bundle_dir"
