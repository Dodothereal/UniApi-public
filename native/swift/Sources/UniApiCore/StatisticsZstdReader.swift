import Foundation
import Darwin
import CZstd

/// A borrowed, already-admitted descriptor. Decoder output goes directly to
/// the existing metadata line reader; source stores are never unpacked on disk.
final class StatisticsZstdReader {
    private let descriptor: Int32
    private let stream: OpaquePointer
    private var input = [UInt8](repeating: 0, count: 1 << 20)
    private var position = 0, available = 0
    private var eof = false, complete = false, sawFrame = false

    init(descriptor: Int32) throws {
        guard let stream = ZSTD_createDStream() else { throw NativeFailure("Compressed usage decoder could not allocate memory") }
        self.descriptor = descriptor; self.stream = stream
        let result = ZSTD_initDStream(stream)
        if ZSTD_isError(result) != 0 {
            ZSTD_freeDStream(stream)
            throw NativeFailure("Compressed usage decoder could not initialize")
        }
    }
    deinit { ZSTD_freeDStream(stream) }

    func read(into output: inout [UInt8]) throws -> Int {
        while true {
            try Task.checkCancellation()
            if position == available && !eof {
                var count: Int
                repeat { count = Darwin.read(descriptor, &input, input.count) } while count < 0 && errno == EINTR
                guard count >= 0 else { throw NativeFailure("Compressed usage ledger read failed") }
                available = count; position = 0; eof = count == 0
            }
            if eof && complete && sawFrame { return 0 }
            let oldPosition = position
            let result: (remaining: Int, produced: Int) = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    var sourceBuffer = ZSTD_inBuffer(src: source.baseAddress, size: available, pos: position)
                    var destinationBuffer = ZSTD_outBuffer(dst: destination.baseAddress, size: destination.count, pos: 0)
                    let remaining = ZSTD_decompressStream(stream, &destinationBuffer, &sourceBuffer)
                    position = sourceBuffer.pos
                    return (remaining, destinationBuffer.pos)
                }
            }
            guard ZSTD_isError(result.remaining) == 0 else { throw NativeFailure("Compressed usage ledger is invalid: \(String(cString: ZSTD_getErrorName(result.remaining)))") }
            complete = result.remaining == 0; sawFrame = sawFrame || complete
            if result.produced > 0 { return result.produced }
            if eof { throw NativeFailure("Compressed usage ledger is empty or truncated") }
            // Concatenated/skippable frames may produce no bytes. A decoder
            // that cannot consume nonempty input must not spin indefinitely.
            if position == oldPosition && position < available { throw NativeFailure("Compressed usage decoder made no progress") }
        }
    }
}
