#!/usr/bin/env bash
set -euo pipefail
# Run on a Mac. Supply static OpenSSL for each SDK/architecture; the resulting
# XCFramework is embedded and signed by CocoaPods/Xcode as part of the app.
: "${LRDP_OPENSSL_ROOT:?Directory containing SDK-ARCH/include and SDK-ARCH/lib}"
: "${LRDP_FFMPEG_ROOT:?Directory containing SDK-ARCH static FFmpeg prefixes}"
task_platform="${1:-macos}"
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_jobs="${LRDP_BUILD_JOBS:-4}"
if [[ "$task_platform" == macos ]]; then
  task_slices=(macosx-arm64 macosx-x86_64)
  task_destination="$task_root/packages/lrdp_native/macos/Frameworks/LRDP.xcframework"
elif [[ "$task_platform" == ios ]]; then
  task_slices=(iphoneos-arm64 iphonesimulator-arm64 iphonesimulator-x86_64)
  task_destination="$task_root/packages/lrdp_native/ios/Frameworks/LRDP.xcframework"
else
  printf '%s\n' 'Usage: build_apple.sh macos|ios' >&2; exit 1
fi
task_output="$task_root/build/apple-$task_platform"
mkdir -p "$task_output"
for task_slice in "${task_slices[@]}"; do
  task_sdk="${task_slice%-*}"; task_arch="${task_slice##*-}"
  task_ssl="$LRDP_OPENSSL_ROOT/$task_slice"
  task_ffmpeg="$LRDP_FFMPEG_ROOT/$task_slice"
  test -f "$task_ssl/lib/libcrypto.a" || { printf 'Missing %s\n' "$task_ssl/lib/libcrypto.a" >&2; exit 1; }
  test -f "$task_ffmpeg/lib/libavcodec.a" || { printf 'Missing %s\n' "$task_ffmpeg/lib/libavcodec.a" >&2; exit 1; }
  task_args=()
  if [[ "$task_platform" == ios ]]; then task_args+=(-DCMAKE_SYSTEM_NAME=iOS -DIOS=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0); fi
  LRDP_FFMPEG_ROOT="$task_ffmpeg" cmake -S "$task_root/native" -B "$task_output/$task_slice" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$task_arch" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$task_sdk" --show-sdk-path)" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE -DOPENSSL_ROOT_DIR="$task_ssl" \
    -DOPENSSL_INCLUDE_DIR="$task_ssl/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$task_ssl/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$task_ssl/lib/libssl.a" \
    -DLRDP_FFMPEG_ROOT="$task_ffmpeg" "${task_args[@]}"
  cmake --build "$task_output/$task_slice" --target lrdp_core -j "$task_jobs"
done
# Merge architectures belonging to the same SDK before creating the XCFramework.
task_framework_args=()
for task_sdk in macosx iphoneos iphonesimulator; do
  task_libraries=()
  for task_slice in "${task_slices[@]}"; do
    if [[ "$task_slice" == "$task_sdk-"* ]]; then task_libraries+=("$task_output/$task_slice/liblrdp.dylib"); fi
  done
  if [[ ${#task_libraries[@]} == 0 ]]; then continue; fi
  task_framework="$task_output/$task_sdk/LRDP.framework"
  mkdir -p "$task_framework/Headers" "$task_framework/Modules"
  lipo -create "${task_libraries[@]}" -output "$task_framework/LRDP"
  install_name_tool -id '@rpath/LRDP.framework/LRDP' "$task_framework/LRDP"
  cp "$task_root/native/include/lrdp.h" "$task_framework/Headers/"
  printf 'framework module LRDP { umbrella header "lrdp.h" export * }\n' > "$task_framework/Modules/module.modulemap"
  TASK_FRAMEWORK="$task_framework" TASK_SDK="$task_sdk" python3 - <<'PY'
import os, plistlib
from pathlib import Path
sdk=os.environ['TASK_SDK']
data={'CFBundleIdentifier':'dev.lrdp.core','CFBundleExecutable':'LRDP',
      'CFBundleName':'LRDP','CFBundlePackageType':'FMWK',
      'CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1',
      'CFBundleSupportedPlatforms':[{'macosx':'MacOSX','iphoneos':'iPhoneOS','iphonesimulator':'iPhoneSimulator'}[sdk]],
      'MinimumOSVersion':'15.0' if sdk != 'macosx' else '11.0'}
Path(os.environ['TASK_FRAMEWORK'],'Info.plist').write_bytes(plistlib.dumps(data))
PY
  task_framework_args+=(-framework "$task_framework")
done
mkdir -p "$(dirname "$task_destination")"
if [[ -e "$task_destination" ]]; then
  printf 'Remove previous generated framework before rebuilding: %s\n' "$task_destination" >&2; exit 1
fi
xcodebuild -create-xcframework "${task_framework_args[@]}" -output "$task_destination"
