import Foundation
import Darwin
import UniApiCore

private var stopping: sig_atomic_t = 0

@main
enum BatteryHelper {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else { throw NativeFailure("Usage: uniapi-battery state|set <percent>|enable|off|daemon <target>") }
            if command == "handoff-clock" { guard args.count == 1 else { throw NativeFailure("Invalid handoff clock arguments") }; print(String(decoding: try NativeBatteryHandoff.clock().encoded(), as: UTF8.self)); return }
            if command == "handoff-files" {
                guard args.count == 6, let owner = UInt32(args[5]) else { throw NativeFailure("Invalid charging file admission arguments") }
                let value = try NativeBatteryHandoff.files(directory: URL(fileURLWithPath: args[1]), binary: URL(fileURLWithPath: args[2]), plist: URL(fileURLWithPath: args[3]), label: args[4], owner: owner)
                print(String(decoding: try value.encoded(), as: UTF8.self)); return
            }
            if command == "handoff-loaded" {
                guard args.count == 4 || args.count == 5 else { throw NativeFailure("Invalid loaded charging job arguments") }
                var data = Data()
                while let block = try FileHandle.standardInput.read(upToCount: 65536), !block.isEmpty {
                    guard data.count + block.count <= 1 << 20 else { throw NativeFailure("Loaded charging job output exceeded its bound") }; data.append(block)
                }
                guard let text = String(data: data, encoding: .utf8) else { throw NativeFailure("Loaded charging job output is invalid") }
                let value = try NativeBatteryHandoff.loaded(text, directory: URL(fileURLWithPath: args[1]), binary: URL(fileURLWithPath: args[2]), label: args[3], admittedInstance: args.count == 5 ? args[4] : nil)
                print(String(decoding: try value.encoded(), as: UTF8.self)); return
            }
            if command == "handoff-ack" {
                guard args.count == 8, let pid = Int32(args[3]), pid > 1, let birth = UInt64(args[4]), let target = Int(args[6]), target == 0 || (25...95).contains(target), ["swift", "legacy"].contains(args[7]), args[5].utf8.count == 64, args[5].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw NativeFailure("Invalid charging acknowledgement arguments") }
                let value = try NativeBatteryHandoff.acknowledgement(directory: URL(fileURLWithPath: args[1]), binary: URL(fileURLWithPath: args[2]), pid: pid, minimumBirth: birth, hash: args[5], target: target, legacy: args[7] == "legacy")
                print(String(decoding: try value.encoded(), as: UTF8.self)); return
            }
            if command == "check-handoff" {
                guard args.count == 3, let owner = UInt32(args[2]), owner >= 500 else { throw NativeFailure("Usage: uniapi-battery check-handoff <state-directory> <local-uid>") }
                let report = try NativeBatteryUpgrade.inspect(directory: URL(fileURLWithPath: args[1]), owner: owner)
                print(String(decoding: try report.encoded(), as: UTF8.self)); return
            }
            if command == "daemon" {
                guard args.count == 2 else { throw NativeFailure("Usage: uniapi-battery daemon <target>") }
                let target = URL(fileURLWithPath: args[1])
                guard target.lastPathComponent == "target" else { throw NativeFailure("The charging daemon accepts only its fixed target inode") }
                let daemon = try NativeBatteryDaemon.production(directory: target.deletingLastPathComponent())
                for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] { signal(number) { _ in stopping = 1 } }
                while stopping == 0 { _ = try daemon.tick(); for _ in 0..<5 { if stopping != 0 { break }; sleep(1) } }
                try daemon.restore(); return
            }
            let client = try NativePowerUIClient()
            let result: JSONValue
            switch command {
            case "state": result = try client.state()
            case "set": guard args.count == 2, let target = Int(args[1]) else { throw NativeFailure("Choose a whole charge-limit percentage") }; result = try client.set(target)
            case "enable": result = try client.enable()
            case "off": result = try client.off()
            default: throw NativeFailure("Unknown charging command; adapter cycling is unavailable")
            }
            print(String(decoding: try result.encoded(), as: UTF8.self))
        } catch { let result: JSONValue = ["ok": false, "error": .string(error.localizedDescription)]; print((try? String(decoding: result.encoded(), as: UTF8.self)) ?? "{}"); exit(1) }
    }
}
