import Foundation

// The dependency-free vision fixture and English filler retain the original
// engine's character/token calibration. Each prompt has a cache-busting nonce.
enum BenchmarkPrompts {
    static let throughput = "Write an extremely long, detailed essay about the history of computing, from mechanical calculators to the present day. Continuous prose only - no lists, no headings. Do not stop early; keep writing until you run out of space."
    static let words = "time year people way day man thing woman life child world school state family student group country problem hand part place case week company system program question work government number night point home water room mother area money story fact month lot right study book eye job word business issue side kind head house service friend father power hour game line end member law car city community name president team minute idea body information back parent face others level office door health person art war history party result change morning reason research girl guy moment air teacher force education".split(separator: " ")
    static func nonce() -> String { "[bench " + UUID().uuidString + "]\n" }
    static func filler(_ tokens: Int, tpc: Double, seed: String) -> String {
        let count = Int(Double(max(0, min(1_100_000, tokens))) / max(0.05, tpc))
        var state = seed.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        var parts: [String] = [], length = 0
        while length < count {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; z ^= z >> 31
            let word = String(words[Int(z % UInt64(words.count))]); parts.append(word); length += word.count + 1
        }
        return parts.joined(separator: " ")
    }
static func tinyPNG() -> Data {
    func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1 }
        }
        return c ^ 0xFFFFFFFF
    }
    func adler32(_ d: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for x in d { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        return (b << 16) | a
    }
    func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
    func chunk(_ tag: String, _ data: Data) -> Data {
        let td = Data(tag.utf8) + data
        return be32(UInt32(data.count)) + td + be32(crc32(td))
    }
    let w = 16, h = 16
    var ihdr = Data()
    ihdr += be32(UInt32(w)) + be32(UInt32(h))
    ihdr += Data([8, 2, 0, 0, 0])
    var raw = Data()
    for _ in 0..<h {
        raw.append(0)
        for _ in 0..<w { raw += Data([0x39, 0x87, 0xE5]) }
    }
    // zlib stream with one stored (uncompressed) deflate block
    var z = Data([0x78, 0x01])
    let len = UInt16(raw.count)
    z += Data([0x01, UInt8(len & 0xFF), UInt8(len >> 8),
               UInt8(~len & 0xFF), UInt8((~len >> 8) & 0xFF)])
    z += raw
    z += be32(adler32(raw))
    return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) +
        chunk("IHDR", ihdr) + chunk("IDAT", z) + chunk("IEND", Data())
}

}
