import Foundation
import Darwin

public enum NativePromptFiles {
    public static let maximumBytes = 50 * 1024 * 1024
    public static let previewBytes = 256 * 1024
    public static func uploadName(_ name: String) -> String {
        let base = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let cleaned = String(base.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? "_" : String($0) }.joined())
        let suffix = (cleaned as NSString).pathExtension
        let ext = suffix.isEmpty || suffix.count > 32 ? "" : "." + suffix
        let stem = ext.isEmpty ? cleaned : String(cleaned.dropLast(ext.count))
        let result = String(stem.prefix(max(0, 240 - ext.count))) + ext
        return result.isEmpty ? "file" : result
    }
    public static func fileExtension(_ name: String) -> String {
        let suffix = (name as NSString).pathExtension.lowercased()
        let valid = suffix.range(of: "^[a-z0-9_-]{1,32}$", options: .regularExpression) != nil
        return valid ? "." + suffix : ".bin"
    }
    public static func type(name: String, sample: Data) -> (kind: String, mime: String) {
        let ext = (name as NSString).pathExtension.lowercased()
        let media: [String: String] = ["html": "text/html", "htm": "text/html", "xhtml": "application/xhtml+xml", "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "avif": "image/avif", "bmp": "image/bmp", "ico": "image/x-icon", "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg", "flac": "audio/flac", "m4a": "audio/mp4", "aac": "audio/aac", "mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime", "m4v": "video/mp4"]
        if let mime = media[ext] {
            return (["text/html", "application/xhtml+xml"].contains(mime) ? "html" : mime == "application/pdf" ? "pdf" : String(mime.split(separator: "/")[0]), mime)
        }
        // A bounded sample can end in the middle of one UTF-8 scalar. Trim
        // only that incomplete suffix, without excusing invalid interior bytes.
        for trim in 0...min(3, sample.count) {
            if trim > 0 {
                let suffix = Array(sample.suffix(trim))
                let first = suffix[0]
                let expected = (0xc2...0xdf).contains(first) ? 2 : (0xe0...0xef).contains(first) ? 3 : (0xf0...0xf4).contains(first) ? 4 : 0
                guard expected > suffix.count, suffix.dropFirst().allSatisfy({ (0x80...0xbf).contains($0) }) else { continue }
                if suffix.count > 1 {
                    if first == 0xe0 && suffix[1] < 0xa0 || first == 0xed && suffix[1] >= 0xa0 || first == 0xf0 && suffix[1] < 0x90 || first == 0xf4 && suffix[1] >= 0x90 { continue }
                }
            }
            let candidate = trim == 0 ? sample : Data(sample.dropLast(trim))
            if let text = String(data: candidate, encoding: .utf8) {
                let controls = text.unicodeScalars.contains { $0.value <= 8 || (14...31).contains($0.value) }
                return controls ? ("binary", "application/octet-stream") : ("text", "text/plain")
            }
        }
        return ("binary", "application/octet-stream")
    }
    public static func hex(_ bytes: Data) -> String {
        let data = Array(bytes.prefix(4096))
        return stride(from: 0, to: data.count, by: 16).map { offset in
            let row = data[offset..<min(offset + 16, data.count)]
            let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = row.map { $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "." }.joined()
            return String(format: "%08x  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
        }.joined(separator: "\n")
    }
    public static func read(_ url: URL, limit: Int = maximumBytes) throws -> (data: Data, size: Int) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw NativeFailure("Result file unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maximumBytes else { throw NativeFailure("Result file unavailable or exceeds 50 MiB") }
        let count = min(Int(info.st_size), max(0, limit))
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if n < 0 { if errno == EINTR { continue }; throw NativeFailure("Could not read result file") }
            if n == 0 { break }
            offset += n
        }
        return (Data(bytes.prefix(offset)), Int(info.st_size))
    }
    static func removeManagedFile(_ url: URL) throws {
        // Match unlink in the server: a directory replacing a managed result
        // is a retryable failure, never authority to recursively delete it.
        if unlink(url.path) != 0 && errno != ENOENT { throw NativeFailure("Managed result cleanup will retry") }
    }
}
