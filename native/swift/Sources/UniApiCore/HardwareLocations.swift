import Foundation
import Darwin

public struct NativeHardwareLocations: Sendable {
    public let paths: NativePaths
    public init(paths: NativePaths) { self.paths = paths }
    private func bundled(_ relative: String, fallback: URL) -> URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent(relative), FileManager.default.fileExists(atPath: resource.path) { return resource }
        return fallback
    }
    public var fanBinary: URL { bundled("Helpers/uniapi-fans", fallback: FileManager.default.isExecutableFile(atPath: paths.root.appendingPathComponent("native/swift/build.noindex/Helpers/uniapi-fans").path) ? paths.root.appendingPathComponent("native/swift/build.noindex/Helpers/uniapi-fans") : paths.data.appendingPathComponent("bin/uniapi-fans")) }
    public var batteryBinary: URL { bundled("Helpers/uniapi-battery", fallback: paths.root.appendingPathComponent("native/swift/build.noindex/Helpers/uniapi-battery")) }
    public var fanInstalled: URL { URL(fileURLWithPath: "/Library/PrivilegedHelperTools/app.devved.uniapi.fans") }
    public var fanPlist: URL { URL(fileURLWithPath: "/Library/LaunchDaemons/app.devved.uniapi.fans.plist") }
    public var fanInstaller: URL { bundled("install-fan-helper.sh", fallback: paths.root.appendingPathComponent("native/fans/install-daemon.sh")) }
    public var fanDaemonSocket: String { "/var/run/app.devved.uniapi.fans-\(getuid())/control.sock" }
    public var fanSessionSocket: String { "/var/run/app.devved.uniapi.fans-\(getuid())/\(getpid()).sock" }
    func fanSocket(owner: Int32) -> String { "/var/run/app.devved.uniapi.fans-\(getuid())/\(owner).sock" }
    public var batteryDirectory: URL { URL(fileURLWithPath: "/Library/Application Support/UniApi/Battery") }
    public var batteryTarget: URL { batteryDirectory.appendingPathComponent("target") }
    public var batteryState: URL { batteryDirectory.appendingPathComponent("state.json") }
    public var batteryInstaller: URL { bundled("install-battery-helper.sh", fallback: paths.root.appendingPathComponent("native/swift/tools/install-battery-helper.sh")) }
    public static var powerUIFramework: String { "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI" }
}
