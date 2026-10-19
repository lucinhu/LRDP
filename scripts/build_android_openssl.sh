#!/usr/bin/env bash
set -euo pipefail
# Source is an unmodified checkout of a maintained OpenSSL 3.x release.
: "${ANDROID_NDK_ROOT:?Set ANDROID_NDK_ROOT to Android NDK r27 or newer}"
: "${LRDP_OPENSSL_SOURCE:?Set LRDP_OPENSSL_SOURCE to an OpenSSL source checkout}"
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="${LRDP_OPENSSL_ROOT:-$task_root/build/deps/android-openssl}"
task_source="$(cd "$LRDP_OPENSSL_SOURCE" && pwd)"
task_jobs="${LRDP_BUILD_JOBS:-4}"
case "$(uname -s)" in
  Linux) task_host=linux-x86_64 ;;
  Darwin) task_host=darwin-x86_64 ;;
  *) printf '%s\n' 'Run this script on Linux or macOS.' >&2; exit 1 ;;
esac
export PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$task_host/bin:$PATH"
for task_abi in "${@:-arm64-v8a}"; do
  case "$task_abi" in
    arm64-v8a) task_target=android-arm64 ;;
    armeabi-v7a) task_target=android-arm ;;
    x86_64) task_target=android-x86_64 ;;
    *) printf 'Unsupported ABI: %s\n' "$task_abi" >&2; exit 1 ;;
  esac
  task_build="$task_root/build/deps/openssl-$task_abi"
  mkdir -p "$task_build" "$task_output/$task_abi"
  (
    cd "$task_build"
    perl "$task_source/Configure" "$task_target" -D__ANDROID_API__=24 \
      no-shared no-tests no-apps no-module no-engine \
      -fPIC -Wl,-z,max-page-size=16384 --libdir=lib --prefix="$task_output/$task_abi"
    make -j "$task_jobs"
    make install_sw
  )
done
printf 'OpenSSL installed under %s\n' "$task_output"
