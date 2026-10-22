#!/usr/bin/env bash
set -euo pipefail
task_appdir="$(dirname "$(readlink -f "$0")")"
export APPDIR="$task_appdir"
# Use the provider matching the bundled libcrypto, including for NLA/NTLM.
export OPENSSL_MODULES="$task_appdir/usr/lib/ossl-modules"
exec "$task_appdir/AppRun.gtk" "$@"
