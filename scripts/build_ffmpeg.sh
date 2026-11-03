#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_source="$(bash "$task_root/scripts/fetch_ffmpeg.sh")"
task_jobs="${LRDP_BUILD_JOBS:-3}"
[[ "$task_jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid LRDP_BUILD_JOBS\n' >&2; exit 1; }
for task_platform in "${@:-linux-x64}"; do
  task_flags=()
  task_linux_hw=off
  task_nvcodec_prefix=
  task_pkg_config_path="${PKG_CONFIG_PATH:-}"
  task_prefix="$task_root/build/deps/ffmpeg/$task_platform"
  case "$task_platform" in
    linux-x64)
      [[ "$(uname -sm)" == 'Linux x86_64' ]] || { printf 'linux-x64 needs a Linux x86_64 host\n' >&2; exit 1; }
      task_flags+=(--arch=x86_64 --target-os=linux)
      # "auto" builds both backends; driver/device availability is checked at runtime.
      # Missing development dependencies must not silently produce a CPU-only build.
      case "${LRDP_LINUX_HW_DECODE:-auto}" in
        auto|AUTO|ON|on|1) task_linux_hw=auto ;;
        OFF|off|0) task_linux_hw=off ;;
        *) printf 'LRDP_LINUX_HW_DECODE must be auto or OFF\n' >&2; exit 1 ;;
      esac
      if [[ "$task_linux_hw" == auto ]]; then
        if ! command -v pkg-config >/dev/null || ! pkg-config --exists 'libva >= 0.35.0' libva-drm libdrm; then
          printf 'Linux hardware decoding requires pkg-config and libva/libva-drm/libdrm development packages. Use LRDP_LINUX_HW_DECODE=OFF for an explicit CPU-only build.\n' >&2
          exit 1
        fi
        task_nvcodec_prefix="$(bash "$task_root/scripts/fetch_nvcodec.sh")"
        task_pkg_config_path="$task_nvcodec_prefix/lib/pkgconfig${task_pkg_config_path:+:$task_pkg_config_path}"
        task_flags+=(--enable-vaapi --enable-libdrm --enable-ffnvcodec
          --enable-cuda --enable-nvdec --disable-cuda-llvm --disable-cuda-nvcc
          --disable-cuvid --disable-nvenc --disable-xlib
          --enable-hwaccel=h264_vaapi --enable-hwaccel=h264_nvdec)
      fi
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
    export PKG_CONFIG_PATH="$task_pkg_config_path"
    "$task_source/configure" --prefix="$task_prefix" \
      --disable-everything --disable-autodetect --disable-network \
      --disable-programs --disable-doc --disable-debug --disable-shared \
      --enable-static --enable-pic --disable-symver \
      --disable-gpl --disable-nonfree --disable-version3 \
      --disable-avformat --disable-avdevice --disable-avfilter --disable-swresample \
      --enable-avcodec --enable-avutil --enable-swscale \
      --enable-decoder=h264 --enable-parser=h264 "${task_flags[@]}"
    if [[ "$task_linux_hw" == auto ]]; then
      python3 - <<'PY'
from pathlib import Path
import re
config=(Path('config.h').read_text()+'\n'+Path('config_components.h').read_text())
required=['CONFIG_'+name for name in ['VAAPI','LIBDRM','CUDA','FFNVCODEC','NVDEC',
          'H264_VAAPI_HWACCEL','H264_NVDEC_HWACCEL']]+['HAVE_VAAPI_DRM']
missing=[name for name in required if not re.search(r'^#define '+name+r' 1$',config,re.M)]
if missing:
    raise SystemExit('Linux hardware decode configuration missing: '+', '.join(missing)+
                     '; install the required development packages or set LRDP_LINUX_HW_DECODE=OFF')
PY
    fi
    make -j "$task_jobs"
    make install
  )
  cp "$task_source/COPYING.LGPLv2.1" "$task_prefix/LICENSE-FFmpeg.txt"
  python3 - "$task_source" "$task_build" "$task_prefix" "$task_platform" \
    "$task_linux_hw" "$task_nvcodec_prefix" "$task_pkg_config_path" <<'PY'
from pathlib import Path
import hashlib,json,os,re,shlex,subprocess,sys
source,build,prefix=map(Path,sys.argv[1:4])
metadata={'version':'9.0.2','platform':sys.argv[4],
 'source_url':'https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz',
 'source_sha256':'8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e',
 'license':'LGPL-2.1-or-later','decoder':'h264','parser':'h264',
 'hardware_acceleration':False,
 'archives':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((prefix/'lib').glob('*.a'))}}
if sys.argv[4]=='linux-x64':
    config=(build/'config.h').read_text()+'\n'+(build/'config_components.h').read_text()
    enabled=lambda name:bool(re.search(r'^#define CONFIG_'+name+r' 1$',config,re.M))
    accelerators=[name for name in ['h264_vaapi','h264_nvdec'] if enabled(name.upper()+'_HWACCEL')]
    contexts=[name for name in ['vaapi','cuda','drm'] if enabled('LIBDRM' if name=='drm' else name.upper())]
    env=dict(os.environ,PKG_CONFIG_PATH=str(prefix/'lib/pkgconfig')+':'+sys.argv[7])
    link_flags=shlex.split(subprocess.check_output(
        ['pkg-config','--static','--libs','libavcodec','libswscale','libavutil'],env=env,text=True))
    metadata.update(hardware_acceleration=bool(accelerators),
        hardware_decode_request=sys.argv[5],hardware_accelerators=accelerators,
        hardware_device_contexts=contexts,hardware_availability='not_probed',
        static_link_flags=link_flags,
        system_link_flags=[flag for flag in link_flags if not flag.startswith('-L'+str(prefix))
                           and flag not in ['-lavcodec','-lswscale','-lavutil']])
    if sys.argv[6]:
        metadata['nv_codec_headers']=json.loads((Path(sys.argv[6])/'BUILD_INFO.json').read_text())
(prefix/'BUILD_INFO.json').write_text(json.dumps(metadata,indent=2)+'\n')
(prefix/'configure-options.txt').write_text((build/'ffbuild/config.log').read_text().splitlines()[0]+'\n')
PY
  printf 'FFmpeg installed under %s\n' "$task_prefix"
done
