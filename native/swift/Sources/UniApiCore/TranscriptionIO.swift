import Foundation

public struct NativeMediaMetadata: Sendable {
    public var file: URL?
    public var title: String?
    public var duration: Double?
    public var bytes: Int?
    public init(file: URL? = nil, title: String? = nil, duration: Double? = nil, bytes: Int? = nil) { self.file = file; self.title = title; self.duration = duration; self.bytes = bytes }
}

/// Tests replace every closure, including tool lookup and credential reads.
/// The production closures are used only for deliberate transcription jobs.
public struct NativeTranscriptionIO: Sendable {
    public var token: @Sendable () throws -> String
    public var available: @Sendable () -> JSONObject
    public var probe: @Sendable (String) async throws -> NativeMediaMetadata
    public var download: @Sendable (String, URL, NativeJobContext) async throws -> NativeMediaMetadata
    public var decode: @Sendable (URL, URL) async throws -> NativeAudioPCM
    public init(token: @escaping @Sendable () throws -> String, available: @escaping @Sendable () -> JSONObject, probe: @escaping @Sendable (String) async throws -> NativeMediaMetadata, download: @escaping @Sendable (String, URL, NativeJobContext) async throws -> NativeMediaMetadata, decode: @escaping @Sendable (URL, URL) async throws -> NativeAudioPCM) {
        self.token = token; self.available = available; self.probe = probe; self.download = download; self.decode = decode
    }
    public static func production(runtime: NativeRuntime) -> NativeTranscriptionIO {
        return NativeTranscriptionIO(token: { "local" }, available: {
            ["localRuntime": .bool(NativeLocalWhisperASR.bundledExecutable != nil), "nativeAudio": true,
             "ffmpeg": .bool(runtime.process.which("ffmpeg") != nil), "ytdlp": .bool(runtime.process.which("yt-dlp") != nil)]
        }, probe: { source in
            guard let tool = runtime.process.which("yt-dlp") else { return NativeMediaMetadata() }
            let result = try await runtime.process.run(tool, arguments: ["--skip-download", "--no-playlist", "--no-warnings", "-f", "bestaudio/best", "--print", "%(duration)s|%(filesize,filesize_approx)s|%(title)s", source], timeout: 40)
            guard result.status == 0, let line = result.output.split(separator: "\n").last else { return NativeMediaMetadata() }
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let duration = parts.first.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let bytes = parts.count > 1 ? Int(parts[1]) : nil
            return NativeMediaMetadata(title: parts.count > 2 ? parts.dropFirst(2).joined(separator: "|") : nil, duration: duration, bytes: bytes)
        }, download: { source, directory, context in
            guard let tool = runtime.process.which("yt-dlp") else { throw NativeFailure("yt-dlp is required for links") }
            let progress = NativeTranscriptionDownloadProgress()
            let reporter = Task {
                for await percent in progress.stream {
                    try? await context.progress(0.02 + 0.28 * percent / 100, text: String(format: "Downloading %.1f%%", percent))
                }
            }
            let result: NativeProcessResult
            do {
                result = try await runtime.process.runStreaming(tool, arguments: ["-f", "bestaudio/best", "--no-playlist", "--restrict-filenames", "--no-warnings", "--newline", "--print-json", "--progress", "-o", directory.appendingPathComponent("%(title).150B.%(ext)s").path, source], onErrorOutput: { progress.receive($0) }, onOutput: { progress.receive($0, isError: false) })
            } catch { progress.finish(); await reporter.value; throw error }
            // Drain the bounded reporter before decode starts; a late download
            // update must not move the next phase's progress backwards.
            progress.finish(); await reporter.value
            guard result.status == 0 else { throw NativeFailure("yt-dlp failed: " + String(result.errorOutput.suffix(400))) }
            let info = result.output.split(separator: "\n").reversed().compactMap { try? JSONValue.decode(Data($0.utf8)) }.first ?? .null
            let candidates = [info["requested_downloads"].array.first?["filepath"].string, info["_filename"].string, info["filename"].string].compactMap { $0 }.filter { !$0.isEmpty }
            let saved = candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]).filter { $0.pathExtension != "part" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            guard let file = saved ?? files.max(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }) else { throw NativeFailure("No audio file was downloaded") }
            let resolved = file.standardizedFileURL.resolvingSymlinksInPath(), root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard resolved.path.hasPrefix(root) else { throw NativeFailure("Downloaded media escaped its work directory") }
            let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            return NativeMediaMetadata(file: resolved, title: info["title"].isNull ? file.deletingPathExtension().lastPathComponent : info["title"].string, duration: info["duration"].isNull ? nil : info["duration"].double, bytes: bytes)
        }, decode: { media, work in
            do { return try NativeLocalAudioDecoder.decode(media, in: work) }
            catch is CancellationError { throw CancellationError() }
            catch {
                guard let tool = runtime.process.which("ffmpeg") else { throw NativeFailure("This media format needs ffmpeg. WAV, MP3 and M4A use the built-in decoder.") }
                return try await decodeWithFFmpeg(tool, media: media, work: work, runtime: runtime)
            }
        })
    }
    private static func decodeWithFFmpeg(_ tool: URL, media: URL, work: URL, runtime: NativeRuntime) async throws -> NativeAudioPCM {
            let decoded = work.appendingPathComponent("audio.pcm")
            // A file plus mmap keeps a long recording out of a second copied
            // stdout buffer; each ASR request allocates only its own chunk.
            let result = try await runtime.process.run(tool, arguments: ["-v", "error", "-y", "-i", media.path, "-ar", "16000", "-ac", "1", "-f", "s16le", decoded.path])
            guard result.status == 0 else { throw NativeFailure("ffmpeg could not decode \(media.lastPathComponent): " + String(result.errorOutput.suffix(300))) }
            let pcm = NativeAudioPCM(data: try Data(contentsOf: decoded, options: .mappedIfSafe))
            guard pcm.samples > 0 else { throw NativeFailure("No audio decoded") }
            return pcm
    }
    static func firstKey(_ data: Data) -> String? {
        let bytes = Array(data), space: Set<UInt8> = [9, 10, 13, 32]
        var i = 0
        while i < bytes.count && space.contains(bytes[i]) { i += 1 }
        guard i < bytes.count && bytes[i] == 123 else { return nil }; i += 1
        while i < bytes.count && space.contains(bytes[i]) { i += 1 }
        guard i < bytes.count && bytes[i] == 34 else { return nil }
        let start = i; i += 1
        var escaped = false
        while i < bytes.count {
            if bytes[i] == 34 && !escaped { return (try? JSONValue.decode(Data(bytes[start...i])))?.string }
            if bytes[i] == 92 { escaped.toggle() } else { escaped = false }
            i += 1
        }
        return nil
    }
}
