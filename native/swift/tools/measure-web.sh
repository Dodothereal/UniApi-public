#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${UNIAPI_SWIFT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
mkdir -p .cache/clang .cache/swift .cache/measurements
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFT_MODULE_CACHE_PATH="$PWD/.cache/swift"
swiftc -O -parse-as-library -sdk "$sdk" -target arm64-apple-macosx14.0 \
  Sources/UniApiCore/JSONValue.swift Sources/UniApiCore/NativePerformance.swift \
  tools/MeasureWeb.swift -o .cache/measure-web
output="${1:-$PWD/.cache/measurements/web-baseline.json}"
.cache/measure-web "$(cd ../.. && pwd)" "$output" "${2:-7}"
