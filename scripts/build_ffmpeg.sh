#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_source="$(bash "$task_root/scripts/fetch_ffmpeg.sh")"
task_jobs="${LRDP_BUILD_JOBS:-3}"
[[ "$task_jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid LRDP_BUILD_JOBS\n' >&2; exit 1; }
for task_platform in "${@:-linux-x64}"; do
  task_flags=()
  task_prefix="$task_root/build/deps/ffmpeg/$task_platform"
  case "$task_platform" in
    linux-x64)
      [[ "$(uname -sm)" == 'Linux x86_64' ]] || { printf 'linux-x64 needs a Linux x86_64 host\n' >&2; exit 1; }
      task_flags+=(--arch=x86_64 --target-os=linux)
      ;;
    windows-x64)
      task_flags+=(--arch=x86_64 --target-os=mingw32 --enable-cross-compile
        --cross-prefix=x86_64-w64-mingw32- --disable-pthreads --enable-w32threads)
      ;;
    android-arm64|android-x64)
      : "${ANDROID_NDK_ROOT:?Set ANDROID_NDK_ROOT to Android NDK r27 or newer}"
      case "$(uname -s)" in
        Linux) task_ndk_host=linux-x86_64 ;;
        Darwin) task_ndk_host=darwin-x86_64 ;;
        *) printf 'Unsupported NDK host\n' >&2; exit 1 ;;
      esac
      task_toolchain="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$task_ndk_host/bin"
      if [[ "$task_platform" == android-arm64 ]]; then
        task_arch=aarch64; task_triple=aarch64-linux-android; task_abi=arm64-v8a
      else
        task_arch=x86_64; task_triple=x86_64-linux-android; task_abi=x86_64
      fi
      task_prefix="$task_root/build/deps/ffmpeg/android/$task_abi"
      task_flags+=(--arch="$task_arch" --target-os=android --enable-cross-compile
        --cc="$task_toolchain/${task_triple}24-clang"
        --cxx="$task_toolchain/${task_triple}24-clang++"
        --ar="$task_toolchain/llvm-ar" --nm="$task_toolchain/llvm-nm"
        --ranlib="$task_toolchain/llvm-ranlib" --strip="$task_toolchain/llvm-strip"
        --extra-ldflags=-Wl,-z,max-page-size=16384)
      ;;
    macosx-arm64|macosx-x86_64|iphoneos-arm64|iphonesimulator-arm64|iphonesimulator-x86_64)
      [[ "$(uname -s)" == Darwin ]] || { printf 'Apple targets need Xcode on a Mac\n' >&2; exit 1; }
      task_sdk="${task_platform%-*}"; task_cpu="${task_platform##*-}"
      task_arch="$task_cpu"
      [[ "$task_cpu" != arm64 ]] || task_arch=aarch64
      case "$task_sdk" in
        macosx) task_min=-mmacosx-version-min=11.0 ;;
        iphoneos) task_min=-miphoneos-version-min=15.0 ;;
        iphonesimulator) task_min=-mios-simulator-version-min=15.0 ;;
      esac
      task_prefix="$task_root/build/deps/ffmpeg/apple/$task_platform"
      task_flags+=(--arch="$task_arch" --target-os=darwin --enable-cross-compile
        --cc="$(xcrun --sdk "$task_sdk" --find clang)"
        --sysroot="$(xcrun --sdk "$task_sdk" --show-sdk-path)"
        --extra-cflags="-arch $task_cpu $task_min"
        --extra-ldflags="-arch $task_cpu $task_min")
      ;;
    *) printf 'Unsupported target: %s\n' "$task_platform" >&2; exit 1 ;;
  esac
  task_build="$task_root/build/deps/ffmpeg-build/$task_platform"
  mkdir -p "$task_build" "$task_prefix"
  (
    cd "$task_build"
    "$task_source/configure" --prefix="$task_prefix" \
      --disable-everything --disable-autodetect --disable-network \
      --disable-programs --disable-doc --disable-debug --disable-shared \
      --enable-static --enable-pic --disable-symver \
      --disable-gpl --disable-nonfree --disable-version3 \
      --disable-avformat --disable-avdevice --disable-avfilter --disable-swresample \
      --enable-avcodec --enable-avutil --enable-swscale \
      --enable-decoder=h264 --enable-parser=h264 "${task_flags[@]}"
    make -j "$task_jobs"
    make install
  )
  cp "$task_source/COPYING.LGPLv2.1" "$task_prefix/LICENSE-FFmpeg.txt"
  python3 - "$task_source" "$task_build" "$task_prefix" "$task_platform" <<'PY'
from pathlib import Path
import hashlib,json,sys
source,build,prefix=map(Path,sys.argv[1:4])
metadata={'version':'9.0.2','platform':sys.argv[4],
 'source_url':'https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz',
 'source_sha256':'8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e',
 'license':'LGPL-2.1-or-later','decoder':'h264','parser':'h264',
 'hardware_acceleration':False,
 'archives':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((prefix/'lib').glob('*.a'))}}
(prefix/'BUILD_INFO.json').write_text(json.dumps(metadata,indent=2)+'\n')
(prefix/'configure-options.txt').write_text((build/'ffbuild/config.log').read_text().splitlines()[0]+'\n')
PY
  printf 'FFmpeg installed under %s\n' "$task_prefix"
done
