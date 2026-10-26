#!/bin/bash
# Build a separate native development bundle. Never install or run it here.
set -euo pipefail
cd "$(dirname "$0")"
source tools/swift-environment.sh
uniapi_swift_environment
sdk="$UNIAPI_SWIFT_SDK"
compiler="$UNIAPI_SWIFT_TOOLCHAIN"
swiftc="$(dirname "$compiler")/swiftc"
configuration="${UNIAPI_NATIVE_CONFIGURATION:-release}"
variant="${UNIAPI_NATIVE_BUNDLE_VARIANT:-development}"
version="${UNIAPI_NATIVE_VERSION:-3.0.0}"
case "$variant" in development|production) ;; *) echo 'Expected development or production bundle.' >&2; exit 64;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected a three-part numeric version.' >&2; exit 64; }
case "$configuration" in debug|release) ;; *) echo 'Expected debug or release build configuration.' >&2; exit 64;; esac
python3 ../../tools/native_manifest.py validate-inputs --repo ../..
python3 ../../tools/generate_statistics_pricing.py --check
export SDKROOT="$sdk" CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift"
build_root="${UNIAPI_NATIVE_BUILD_ROOT:-$PWD/build.noindex}"
[[ "$build_root" == /* && ! -L "$build_root" ]] || { echo 'Expected an unlinked absolute build directory.' >&2; exit 1; }
[[ ! -L "$build_root/Helpers" ]] || { echo 'Linked helper output directory refused.' >&2; exit 1; }
for helper in uniapi-fans uniapi-battery uniapi-shim uniapi-whisper; do
  [[ ! -L "$build_root/Helpers/$helper" ]] || { echo 'Linked helper output refused.' >&2; exit 1; }
done
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$build_root/Helpers"
bash ../../tools/build-local-whisper.sh --output "$build_root/Helpers/uniapi-whisper"
"$compiler" build --build-system native --disable-sandbox --sdk "$sdk" --cache-path "$PWD/.cache/swiftpm" -c "$configuration" -j 2 -Xswiftc -num-threads -Xswiftc 2
binary_dir="$("$compiler" build --build-system native --disable-sandbox --sdk "$sdk" -c "$configuration" --show-bin-path)"
fan_temporary="$(mktemp "$build_root/Helpers/uniapi-fans.XXXXXX")"
trap 'rm -f "$fan_temporary"' EXIT
"$swiftc" -O -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" ../fans/Core/*.swift ../fans/main.swift -framework IOKit -o "$fan_temporary"
codesign --force --sign - --identifier uniapi-fans "$fan_temporary"
mv -f "$fan_temporary" "$build_root/Helpers/uniapi-fans"
trap - EXIT
if [[ "$variant" == production ]]; then
  final_app="$build_root/UniApi.app"
else
  final_app="$build_root/UniApi Native.app"
fi
app="$(mktemp -d "$build_root/.native-bundle.XXXXXX")/UniApi.app"
staging="$(dirname "$app")"
trap 'rm -rf "$staging"' EXIT
python3 ../../tools/native_manifest.py stage-app --repo ../.. --bin-dir "$binary_dir" \
  --fan-helper "$build_root/Helpers/uniapi-fans" --whisper-helper "$build_root/Helpers/uniapi-whisper" --app "$app" --variant "$variant" --version "$version"
for helper in uniapi-battery uniapi-shim; do
  helper_temporary="$(mktemp "$build_root/Helpers/$helper.XXXXXX")"
  trap 'rm -f "$helper_temporary"; rm -rf "$staging"' EXIT
  cp "$app/Contents/Resources/Helpers/$helper" "$helper_temporary"
  mv -f "$helper_temporary" "$build_root/Helpers/$helper"
  trap 'rm -rf "$staging"' EXIT
done
for executable in "$app/Contents/MacOS/UniApiNative" \
  "$app/Contents/Resources/Helpers/uniapi-fans" "$app/Contents/Resources/Helpers/uniapi-battery" "$app/Contents/Resources/Helpers/uniapi-shim" "$app/Contents/Resources/Helpers/uniapi-whisper"; do
  minimum="$(vtool -show-build "$executable" | awk '/minos/ {print $2}')"
  [[ "$minimum" == 14.0 ]] || { echo "Unexpected minimum macOS version: $minimum" >&2; exit 1; }
  # Keep original build products for diagnostics; release copies need neither
  # local/debug symbols nor their embedded build paths. Sign after stripping.
  if [[ "$variant" == production ]]; then strip -S -x "$executable"; fi
  codesign --force --sign - "$executable"
done
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
python3 ../../tools/native_manifest.py validate-app --app "$app" --variant "$variant" --version "$version"
[[ ! -L "$final_app" ]] || { echo 'Linked build bundle refused.' >&2; exit 1; }
rm -rf "$final_app"
mv "$app" "$final_app"
echo "Built $final_app; installed app and device helpers were not changed."
