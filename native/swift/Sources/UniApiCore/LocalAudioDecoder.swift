import Foundation
import AVFoundation

/// System audio formats need no external decoder. Unsupported containers can use ffmpeg.
public enum NativeLocalAudioDecoder {
    public static func decode(_ media: URL, in work: URL) throws -> NativeAudioPCM {
        let source = try AVAudioFile(forReading: media)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source.processingFormat, to: format) else { throw NativeFailure("Audio format cannot be converted") }
        // AVAudioConverter defaults to channel selection; explicitly mix stereo
        // so speech present only on the right channel is not silently discarded.
        converter.downmix = true
        let destination = work.appendingPathComponent("audio.pcm")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw NativeFailure("Cannot create decoded audio") }
        let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
        var readError: Error?
        while true {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000) else { throw NativeFailure("Cannot allocate audio buffer") }
            var conversionError: NSError?
            let result = converter.convert(to: output, error: &conversionError) { count, state in
                do {
                    // AVAudioFile may throw eofErr on a further read after the
                    // last complete buffer. Announce EOF before asking it again.
                    guard source.framePosition < source.length else { state.pointee = .endOfStream; return nil }
                    let capacity = AVAudioFrameCount(min(Int64(min(count, 32768)), source.length - source.framePosition))
                    guard let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: capacity) else { throw NativeFailure("Cannot allocate source audio") }
                    try source.read(into: input)
                    state.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if output.frameLength > 0, let bytes = output.int16ChannelData?[0] {
                try file.write(contentsOf: Data(bytes: bytes, count: Int(output.frameLength) * 2))
            }
            if result == .endOfStream { break }
            guard result != .error else { throw NativeFailure("Audio conversion failed") }
        }
        try file.synchronize()
        let pcm = NativeAudioPCM(data: try Data(contentsOf: destination, options: .mappedIfSafe))
        guard pcm.samples > 0 else { throw NativeFailure("No audio decoded") }
        return pcm
    }
}
