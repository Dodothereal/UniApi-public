import XCTest
import Foundation
import Darwin
@testable import UniApiCore

final class LocalAudioDecoderTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("local-audio-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // Independent RIFF fixture builder, not NativeAudioPCM.wav (the code under test).
    private func wav(_ samples: [Int16], rate: Int, channels: Int) -> Data {
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); word(UInt32(36 + samples.count * 2)); ascii("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(channels)); word(UInt32(rate))
        word(UInt32(rate * channels * 2)); word(UInt16(channels * 2)); word(UInt16(16))
        ascii("data"); word(UInt32(samples.count * 2))
        for sample in samples { word(sample) }
        return data
    }

    private func samples(_ pcm: NativeAudioPCM) -> [Double] {
        pcm.data.withUnsafeBytes { raw in
            (0..<pcm.samples).map { Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) }
        }
    }

    func testProductionDecoderPreservesKnownMonoPCMAndPrivateOutput() throws {
        let work = try directory(), input = work.appendingPathComponent("known.wav")
        let expected: [Int16] = (0..<16000).map { index in
            let pattern: [Int16] = [-24000, -12000, -1, 0, 1, 12000, 24000, 0]
            return pattern[index % pattern.count]
        }
        try wav(expected, rate: 16000, channels: 1).write(to: input)
        let pcm = try NativeLocalAudioDecoder.decode(input, in: work)
        XCTAssertEqual(pcm.samples, expected.count)
        XCTAssertEqual(pcm.duration, 1, accuracy: 0.0001)
        let decoded = samples(pcm)
        guard decoded.count == expected.count else { return XCTFail("Decoder returned an unexpected sample count") }
        for index in expected.indices {
            XCTAssertEqual(decoded[index], Double(expected[index]), accuracy: 1, "Sample \(index)")
        }
        let output = work.appendingPathComponent("audio.pcm")
        XCTAssertEqual(try Data(contentsOf: output), pcm.data)
        var info = stat(); XCTAssertEqual(lstat(output.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, mode_t(0o600))
        XCTAssertEqual(info.st_size, off_t(expected.count * 2))
    }

    func testProductionResamplerConverts48kStereoTo16kMonoWithoutChangingPitch() throws {
        let work = try directory(), input = work.appendingPathComponent("stereo48k.wav")
        var source: [Int16] = []; source.reserveCapacity(96000)
        for index in 0..<48000 {
            let sample = Int16((12000 * sin(2 * .pi * 440 * Double(index) / 48000)).rounded())
            source.append(sample); source.append(sample)
        }
        try wav(source, rate: 48000, channels: 2).write(to: input)
        let pcm = try NativeLocalAudioDecoder.decode(input, in: work)
        XCTAssertLessThanOrEqual(abs(pcm.samples - 16000), 32)
        XCTAssertEqual(pcm.duration, 1, accuracy: 0.002)
        let decoded = samples(pcm)
        guard decoded.count > 640 else { return XCTFail("Resampler produced too little audio") }
        let range = 320..<(decoded.count - 320)
        var sine = 0.0, cosine = 0.0, energy = 0.0
        for index in range {
            let angle = 2 * Double.pi * 440 * Double(index) / 16000
            sine += decoded[index] * sin(angle); cosine += decoded[index] * cos(angle)
            energy += decoded[index] * decoded[index]
        }
        let amplitude = 2 * hypot(sine, cosine) / Double(range.count)
        XCTAssertEqual(amplitude, 12000, accuracy: 600)
        XCTAssertEqual(sqrt(energy / Double(range.count)), 12000 / sqrt(2), accuracy: 600)
        XCTAssertEqual(pcm.data.count, pcm.samples * 2)
    }

    func testStereoOppositePolarityChannelsDownmixToSilence() throws {
        let work = try directory(), input = work.appendingPathComponent("opposite.wav")
        var source: [Int16] = []
        for index in 0..<16000 {
            let value = Int16((8000 * sin(2 * .pi * 220 * Double(index) / 16000)).rounded())
            source.append(value); source.append(-value)
        }
        try wav(source, rate: 16000, channels: 2).write(to: input)
        let pcm = try NativeLocalAudioDecoder.decode(input, in: work)
        XCTAssertEqual(pcm.samples, 16000)
        XCTAssertLessThanOrEqual(samples(pcm).map { abs($0) }.max() ?? .infinity, 2)
    }

    func testCancellationThrowsBeforeProducingUsablePCM() async throws {
        let work = try directory(), input = work.appendingPathComponent("cancel.wav")
        try wav([Int16](repeating: 1200, count: 16000), rate: 16000, channels: 1).write(to: input)
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try NativeLocalAudioDecoder.decode(input, in: work); return false }
            catch is CancellationError { return true }
            catch { XCTFail("Unexpected cancellation error: \(error)"); return false }
        }
        let cancelled = await task.value; XCTAssertTrue(cancelled)
        let output = work.appendingPathComponent("audio.pcm")
        if FileManager.default.fileExists(atPath: output.path) {
            XCTAssertTrue(try Data(contentsOf: output).isEmpty)
        }
    }

    func testMissingMalformedEmptyAudioAndUnavailableOutputThrow() throws {
        let work = try directory()
        XCTAssertThrowsError(try NativeLocalAudioDecoder.decode(work.appendingPathComponent("missing.wav"), in: work))
        let invalid = work.appendingPathComponent("malformed.wav")
        try Data("not an audio container".utf8).write(to: invalid)
        XCTAssertThrowsError(try NativeLocalAudioDecoder.decode(invalid, in: work))
        let empty = work.appendingPathComponent("empty.wav")
        try wav([], rate: 16000, channels: 1).write(to: empty)
        XCTAssertThrowsError(try NativeLocalAudioDecoder.decode(empty, in: work))
        let valid = work.appendingPathComponent("valid.wav")
        try wav([1000, -1000], rate: 16000, channels: 1).write(to: valid)
        let missingWork = work.appendingPathComponent("absent-directory")
        XCTAssertThrowsError(try NativeLocalAudioDecoder.decode(valid, in: missingWork))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingWork.path))
    }
}
