// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UniApiNative",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "UniApiNative", targets: ["UniApi"]), .executable(name: "uniapi-battery", targets: ["UniApiBatteryHelper"]), .executable(name: "uniapi-shim", targets: ["UniApiShim"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .systemLibrary(name: "CNativeSystem"),
        .target(name: "CZstd", exclude: ["LICENSE", "COPYING", "NOTICE.md"]),
        .target(name: "UniApiCore", dependencies: ["CSQLite", "CNativeSystem", "CZstd"]),
        .target(name: "UniApiPresentation", dependencies: ["UniApiCore"]),
        .executableTarget(name: "UniApi", dependencies: ["UniApiCore", "UniApiPresentation"]),
        .executableTarget(name: "UniApiBatteryHelper", dependencies: ["UniApiCore"]),
        .executableTarget(name: "UniApiShim", dependencies: ["UniApiCore"]),
        .testTarget(name: "UniApiCoreTests", dependencies: ["UniApiCore"], exclude: ["Fixtures"]),
        .testTarget(name: "UniApiPresentationTests", dependencies: ["UniApiPresentation", "UniApiCore"])
    ],
    swiftLanguageModes: [.v5]
)
