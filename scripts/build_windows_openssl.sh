#!/usr/bin/env bash
set -euo pipefail
# MinGW cross build of the same unmodified OpenSSL source used on Android.
: "${LRDP_OPENSSL_SOURCE:?Set LRDP_OPENSSL_SOURCE to an OpenSSL 3.x source checkout}"
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_source="$(cd "$LRDP_OPENSSL_SOURCE" && pwd)"
task_output="${LRDP_WINDOWS_OPENSSL_ROOT:-$task_root/build/deps/windows-openssl/x64}"
task_build="$task_root/build/deps/openssl-windows-x64"
task_jobs="${LRDP_BUILD_JOBS:-4}"
command -v x86_64-w64-mingw32-gcc >/dev/null
mkdir -p "$task_build" "$task_output"
(
  cd "$task_build"
  perl "$task_source/Configure" mingw64 --cross-compile-prefix=x86_64-w64-mingw32- \
    no-shared no-tests no-apps no-module no-engine --libdir=lib --prefix="$task_output"
  make -j "$task_jobs"
  make install_sw
)
printf 'Windows x64 OpenSSL installed under %s\n' "$task_output"
