import Foundation

@main
enum MeasureWeb {
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 3 else { throw NativeFailure("Usage: measure-web <repository-root> <output-json> [samples]") }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let destination = URL(fileURLWithPath: CommandLine.arguments[2])
            let samples = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 7 : 7
            let result = try await NativeWebBaseline.collect(root: root, samples: samples)
            try result.encoded(pretty: true).write(to: destination, options: .atomic)
            for row in result["routes"].array {
                let median = row["warmMedianMs"].isNull ? "-" : String(format: "%.2f ms", row["warmMedianMs"].double)
                print("\(row["page"].string): warm API median \(median), statuses \(row["statuses"].array.map(\.int)), errors \(row["errors"].array.count)")
            }
            print("Baseline recorded: \(destination.lastPathComponent)")
        } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
}
