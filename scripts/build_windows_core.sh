#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_ssl="${LRDP_WINDOWS_OPENSSL_ROOT:-$task_root/build/deps/windows-openssl/x64}"
task_build="$task_root/build/windows-x64"
task_ffmpeg="${LRDP_FFMPEG_ROOT:-$task_root/build/deps/ffmpeg/windows-x64}"
for task_required in include/openssl/ssl.h lib/libssl.a lib/libcrypto.a; do
  test -f "$task_ssl/$task_required" || {
    printf 'Missing Windows x64 OpenSSL: %s\n' "$task_ssl/$task_required" >&2
    exit 1
  }
done
cmake -S "$task_root/native" -B "$task_build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$task_root/cmake/toolchains/mingw64.cmake" \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_WINDOWS_VERSION=WIN10 \
  -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=TRUE \
  -DOPENSSL_USE_STATIC_LIBS=TRUE -DOPENSSL_ROOT_DIR="$task_ssl" \
  -DOPENSSL_INCLUDE_DIR="$task_ssl/include" \
  -DOPENSSL_SSL_LIBRARY="$task_ssl/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$task_ssl/lib/libcrypto.a" \
  -DLRDP_FFMPEG_ROOT="$task_ffmpeg" \
  -DLRDP_BUILD_TESTS=ON
cmake --build "$task_build" --target lrdp_core lrdp_bridge_test lrdp_video_store_test lrdp_windows_protocol lrdp_cursor_test lrdp_paste_test lrdp_audio_test lrdp_input_stop_test -j "${LRDP_BUILD_JOBS:-4}"
printf 'Windows x64 core built under %s\n' "$task_build"
