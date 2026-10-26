import Foundation
import CZstd

/// Decode only the two request encodings used by Codex. No shell, temporary
/// extraction or unbounded decompressed allocation is involved.
enum NativeCodexRequestBody {
    static func decode(_ input: Data, encoding: String?, limit: Int = ShimSecurity.maximumBody) throws -> Data {
        guard limit > 0, input.count <= limit else { throw NativeFailure("Codex request exceeds its byte bound") }
        let format = (encoding ?? "identity").trimmingCharacters(in: .whitespaces).lowercased()
        if format.isEmpty || format == "identity" { return input }
        guard format == "zstd", !input.isEmpty, let stream = ZSTD_createDStream() else { throw NativeFailure("Unsupported or invalid Codex request encoding") }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { throw NativeFailure("Cannot initialize Codex request decoder") }
        return try input.withUnsafeBytes { bytes in
            var source = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
            var buffer = [UInt8](repeating: 0, count: 65536), output = Data()
            while true {
                try Task.checkCancellation()
                let old = source.pos
                let decoded = buffer.withUnsafeMutableBytes { destination -> (Int, Int) in
                    var target = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let remaining = ZSTD_decompressStream(stream, &target, &source)
                    return (remaining, target.pos)
                }
                guard ZSTD_isError(decoded.0) == 0, output.count <= limit - decoded.1 else { throw NativeFailure("Invalid or oversized compressed Codex request") }
                output.append(contentsOf: buffer.prefix(decoded.1))
                if decoded.0 == 0 && source.pos == source.size { return output }
                guard source.pos != old || decoded.1 > 0 else { throw NativeFailure("Truncated compressed Codex request") }
            }
        }
    }
}
