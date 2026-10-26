#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 ../../tools/generate_statistics_pricing.py --check
sdk="${UNIAPI_SWIFT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$sdk" ]]; then
  echo "Required SwiftUI-compatible SDK unavailable: $sdk" >&2
  exit 1
fi
export SDKROOT="$sdk"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
compiler="${UNIAPI_SWIFT_TOOLCHAIN:-/Library/Developer/CommandLineTools/usr/bin/swift}"
# The optimized Home failure was invisible to debug-only tests.
"$compiler" test --build-system native --disable-sandbox --sdk "$sdk" --cache-path "$PWD/.cache/swiftpm" -c release -j 2 -Xswiftc -num-threads -Xswiftc 2 "$@"
