import Foundation
@main struct Probe {
    static func main() throws {
        let hardware = try Hardware()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        print(String(data:try encoder.encode(hardware.snapshot()),encoding:.utf8)!)
    }
}
