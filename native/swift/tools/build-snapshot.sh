#!/bin/bash
# Freeze source before an optimized compile while independent workers edit.
# Produces only executables for profiling; does not install or launch anything.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/swift-environment.sh
uniapi_swift_environment
python3 ../../tools/generate_statistics_pricing.py --check >&2
sdk="$UNIAPI_SWIFT_SDK"
configuration="${UNIAPI_NATIVE_CONFIGURATION:-release}"
compiler="$UNIAPI_SWIFT_TOOLCHAIN"
case "$configuration" in debug|release) ;; *) exit 64;; esac
mkdir -p .cache
# Keep each immutable source and its executable together for later profiling.
# Another invocation cannot delete the source or scratch tree of an active build.
work="$(mktemp -d "$PWD/.cache/$configuration-snapshot.XXXXXX")"
mkdir -p "$work/clang" "$work/swift"
cp -R Sources "$work/Sources"
cp -R Tests "$work/Tests"
cp Package.swift "$work/Package.swift"
export SDKROOT="$sdk" CLANG_MODULE_CACHE_PATH="$work/clang" SWIFTPM_MODULECACHE_OVERRIDE="$work/swift"
"$compiler" build --package-path "$work" --build-system native --disable-sandbox --sdk "$sdk" \
  --scratch-path "$work/build" --cache-path "$PWD/.cache/swiftpm" -c "$configuration" --product UniApiNative -j 2 -Xswiftc -num-threads -Xswiftc 2 >&2
"$compiler" build --package-path "$work" --build-system native --disable-sandbox --sdk "$sdk" \
  --scratch-path "$work/build" -c "$configuration" --show-bin-path
