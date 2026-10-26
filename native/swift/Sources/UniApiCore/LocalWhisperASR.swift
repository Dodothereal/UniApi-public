import Foundation

/// One owned child per transcription. The model leaves memory when that child exits.
public struct NativeLocalWhisperASR: Sendable {
    public typealias Progress = @Sendable (Int, Int, Int?, String?) async throws -> Void
    private let models: NativeLocalWhisperModels
    private let process: NativeProcess
    private let temporary: URL
    private let executable: URL?
    public init(models: NativeLocalWhisperModels, process: NativeProcess, temporary: URL, executable: URL? = nil) {
        self.models = models; self.process = process; self.temporary = temporary
        self.executable = executable ?? Self.bundledExecutable
    }
    public static var bundledExecutable: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let file = resources.appendingPathComponent("Helpers/uniapi-whisper")
        return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }
    public func transcribe(_ pcm: NativeAudioPCM, language: String?, completed: [Int: String] = [:], progress: @escaping Progress) async throws -> JSONValue {
        let ranges = pcm.bounds()
        guard !ranges.isEmpty else { throw NativeFailure("No audio decoded") }
        var parts = ranges.indices.map { completed[$0] }
        let pending = ranges.indices.filter { parts[$0] == nil }
        if !pending.isEmpty {
            guard let executable else { throw NativeFailure("The bundled local Whisper runtime is missing; reinstall UniApi") }
            let work = temporary.appendingPathComponent("local-whisper-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: work) }
            var arguments = ["-l", language.flatMap { $0.isEmpty ? nil : $0 } ?? "auto", "-otxt", "-np", "-t", "4"]
            for index in pending {
                let wav = work.appendingPathComponent("chunk-\(index).wav")
                try NativeFile.writeAtomic(pcm.wav(ranges[index]), to: wav)
                arguments += ["-f", wav.path, "-of", work.appendingPathComponent("text-\(index)").path]
            }
            try await progress(parts.compactMap { $0 }.count, ranges.count, nil, nil)
            let commandArguments = arguments
            let result = try await models.withModel { model in
                try await process.run(executable, arguments: ["-m", model.path] + commandArguments,
                    environment: ["PATH": "/usr/bin:/bin", "HOME": work.path, "TMPDIR": work.path], directory: work,
                    timeout: min(21600, max(120, pcm.duration * 4 + 60)))
            }
            try Task.checkCancellation()
            guard result.status == 0 else { throw NativeFailure("Local Whisper failed: " + String(result.errorOutput.suffix(600))) }
            for index in pending {
                let output = work.appendingPathComponent("text-\(index).txt")
                let text = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                parts[index] = text
                try await progress(parts.compactMap { $0 }.count, ranges.count, index, text)
            }
        } else { try await progress(ranges.count, ranges.count, nil, nil) }
        let texts = parts.map { $0 ?? "" }
        return ["text": .string(texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)),
                "parts": .array(texts.map(JSONValue.string)), "gaps": [], "totalSec": .number(pcm.duration)]
    }
}
