import Foundation

enum NativeBatteryExecutable {
    static func identity() throws -> String {
        guard let url = Bundle.main.executableURL else { throw NativeFailure("Charging controller executable is unavailable") }
        return try NativeBatteryHandoffFile.read(url, role: .executable)!.hash
    }
}
