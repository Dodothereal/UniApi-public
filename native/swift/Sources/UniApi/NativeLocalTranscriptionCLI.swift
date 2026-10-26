import Foundation
import UniApiCore

/// These explicit commands do not create the app session or start hardware/background services.
enum NativeLocalTranscriptionCLI {
    static func run(_ arguments: [String]) async throws -> Int32 {
        let paths = NativePaths.discover()
        let models = NativeLocalWhisperModels(paths: paths)
        if arguments.first == "--local-model" {
            guard arguments.count == 2 else { throw NativeFailure("Usage: --local-model status|install|remove") }
            switch arguments[1] {
            case "status": break
            case "install":
                try paths.ensureDirectories()
                try await models.install { fraction, message in fputs("\(Int(fraction * 100))% \(message)\n", stderr) }
            case "remove": try await models.remove()
            default: throw NativeFailure("Usage: --local-model status|install|remove")
            }
            print(String(decoding: try await models.status().encoded(), as: UTF8.self))
            return 0
        }
        guard arguments.first == "--transcribe-file", arguments.count == 2 || arguments.count == 4,
              arguments[1].hasPrefix("/"), arguments.count == 2 || arguments[2] == "--language" else {
            throw NativeFailure("Usage: --transcribe-file /absolute/audio-file [--language en]")
        }
        try paths.assertWritable(); try paths.ensureDirectories()
        let work = paths.tmp.appendingPathComponent("transcribe-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let pcm = try NativeLocalAudioDecoder.decode(URL(fileURLWithPath: arguments[1]), in: work)
        let recognizer = NativeLocalWhisperASR(models: models, process: NativeProcess(), temporary: work)
        let result = try await recognizer.transcribe(pcm, language: arguments.count == 4 ? arguments[3] : nil) { done, total, _, _ in
            fputs("Transcribed \(done)/\(total) chunks\n", stderr)
        }
        print(result["text"].string)
        return 0
    }
}
