#!/bin/bash
# Isolated optimized media/jobs acceptance; preserves its immutable source and log.
# Coordinate the compiler slot with other migration workers before invoking.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/swift-environment.sh
uniapi_swift_environment
media_work="$(mktemp -d "${TMPDIR:-/tmp}/uniapi-media-jobs.XXXXXX")"
mkdir -p "$media_work/source/Sources/UniApiCore" "$media_work/source/Sources/CSQLite" "$media_work/source/Sources/CNativeSystem" "$media_work/source/Tests/UniApiCoreTests" "$media_work/clang" "$media_work/swift"
for media_source in JSONValue CoreProviderStore NativeCache NativeDashboard NativeDatabase NativeEvents NativeHex NativeJobs NativeNotifications NativeOwnership NativePaths NativePerformance NativeProcess NativeRuntime NativeTransferProcess NativeTransferBarrier; do
  cp "Sources/UniApiCore/$media_source.swift" "$media_work/source/Sources/UniApiCore/"
done
cp Sources/UniApiCore/Prompts*.swift Sources/UniApiCore/Transcription*.swift "$media_work/source/Sources/UniApiCore/"
cp Sources/CSQLite/* "$media_work/source/Sources/CSQLite/"
cp Sources/CNativeSystem/* "$media_work/source/Sources/CNativeSystem/"
cp Tests/UniApiCoreTests/CoreTests.swift Tests/UniApiCoreTests/PromptsTests.swift Tests/UniApiCoreTests/Transcription*Tests.swift Tests/UniApiCoreTests/Media*AcceptanceTests.swift "$media_work/source/Tests/UniApiCoreTests/"
cat > "$media_work/source/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "UniApiMediaJobsAcceptance", platforms: [.macOS(.v14)], targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .systemLibrary(name: "CNativeSystem"),
    .target(name: "UniApiCore", dependencies: ["CSQLite", "CNativeSystem"]),
    .testTarget(name: "UniApiCoreTests", dependencies: ["UniApiCore"])
], swiftLanguageModes: [.v5])
SWIFT
python3 - "$media_work/source" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}
(root.parent / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
export SDKROOT="$UNIAPI_SWIFT_SDK" CLANG_MODULE_CACHE_PATH="$media_work/clang" SWIFTPM_MODULECACHE_OVERRIDE="$media_work/swift"
printf 'Immutable source and logs: %s\n' "$media_work"
"$UNIAPI_SWIFT_TOOLCHAIN" test --package-path "$media_work/source" --build-system native --disable-sandbox --sdk "$UNIAPI_SWIFT_SDK" \
  --scratch-path "$media_work/build" --cache-path "$media_work/swiftpm-cache" -c release -j 2 -Xswiftc -num-threads -Xswiftc 2 "$@" 2>&1 | tee "$media_work/test.log"
