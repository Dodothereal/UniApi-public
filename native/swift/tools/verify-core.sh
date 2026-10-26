#!/bin/bash
# Validate the shared runtime while independent domain ports are being edited.
# The complete application gate remains verify.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/swift-environment.sh
uniapi_swift_environment
sdk="$UNIAPI_SWIFT_SDK"
work="$(mktemp -d "${TMPDIR:-/tmp}/uniapi-native-core.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/UniApiCore" "$work/Sources/CSQLite" "$work/Sources/CNativeSystem" "$work/Tests/UniApiCoreTests" .cache/clang .cache/swift
mkdir -p "$work/Tests/UniApiCoreTests/Fixtures"
for source in JSONValue CoreProviderStore NativeCache NativeDashboard NativeDatabase NativeEvents NativeHex NativeJobs NativeNotifications NativeOwnership NativePaths NativePerformance NativeProcess NativeRuntime NativeTransferProcess NativeTransferBarrier; do
  cp "Sources/UniApiCore/$source.swift" "$work/Sources/UniApiCore/"
done
cp Sources/CSQLite/* "$work/Sources/CSQLite/"
cp Sources/CNativeSystem/* "$work/Sources/CNativeSystem/"
cp -R Sources/CZstd "$work/Sources/CZstd"
cp Tests/UniApiCoreTests/CoreTests.swift "$work/Tests/UniApiCoreTests/"
cp Tests/UniApiCoreTests/TransferProcessTests.swift "$work/Tests/UniApiCoreTests/"
cp Tests/UniApiCoreTests/TransferBarrierTests.swift "$work/Tests/UniApiCoreTests/"
if [[ "${1:-}" == "--with-initial-domains" ]]; then
  shift
  cp Sources/UniApiCore/Statistics*.swift Sources/UniApiCore/Prompts*.swift Sources/UniApiCore/Transcription*.swift "$work/Sources/UniApiCore/"
  cp Tests/UniApiCoreTests/Statistics*.swift Tests/UniApiCoreTests/Prompts*.swift Tests/UniApiCoreTests/Transcription*.swift "$work/Tests/UniApiCoreTests/"
  cp -R Tests/UniApiCoreTests/Fixtures "$work/Tests/UniApiCoreTests/"
fi
if [[ "${1:-}" == "--with-hardware" ]]; then
  shift
  cp Sources/UniApiCore/Hardware*.swift "$work/Sources/UniApiCore/"
  cp Tests/UniApiCoreTests/Hardware*.swift "$work/Tests/UniApiCoreTests/"
fi
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "UniApiCoreValidation", platforms: [.macOS(.v14)], targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .systemLibrary(name: "CNativeSystem"),
    .target(name: "CZstd", exclude: ["LICENSE", "COPYING", "NOTICE.md"]),
    .target(name: "UniApiCore", dependencies: ["CSQLite", "CNativeSystem", "CZstd"]),
    .testTarget(name: "UniApiCoreTests", dependencies: ["UniApiCore"], exclude: ["Fixtures"])
], swiftLanguageModes: [.v5])
SWIFT
export SDKROOT="$sdk"
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift"
"$UNIAPI_SWIFT_TOOLCHAIN" test --package-path "$work" --build-system native --disable-sandbox --sdk "$sdk" \
  --scratch-path "$work/build" --cache-path "$PWD/.cache/swiftpm" -c release -j 2 -Xswiftc -num-threads -Xswiftc 2 "$@"
