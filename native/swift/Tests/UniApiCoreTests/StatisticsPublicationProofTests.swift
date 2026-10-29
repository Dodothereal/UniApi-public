import XCTest
@testable import UniApiCore

final class StatisticsPublicationProofTests: XCTestCase {
    private func row(_ id: String = "fresh", model: String = "fixture-model-long") -> StatisticsUsage {
        StatisticsUsage(id: id, source: "codex", ts: 20, model: model)
    }
    func testRecordProofChecksUnicodeSpellingOptionalStringsAndDoubleBits() {
        let original = row(model: "caf\u{e9}-model-0123456789")
        var changed = original
        changed.model = "cafe\u{301}-model-0123456789"
        XCTAssertEqual(original.model, changed.model)
        XCTAssertFalse(original.matchesBytes(of: changed))
        changed = original; changed.input = -0.0
        XCTAssertEqual(original.input, changed.input)
        XCTAssertFalse(original.matchesBytes(of: changed))
        changed = original; changed.streamDurationMs = 0
        XCTAssertFalse(original.matchesBytes(of: changed))
        changed = original; changed.streamTiming = ""
        XCTAssertFalse(original.matchesBytes(of: changed))
        XCTAssertTrue(original.matchesBytes(of: original))
    }
    func testMembershipNeverMissesCanonicalUnicodeOrCompositeKeysAndSaturationIsUncertainty() {
        var filter = StatisticsRecordMembership()
        let inputs = (0..<10_000).map { "codex:record:\($0)" } + ["codex:caf\u{e9}", "x:y:z"]
        for key in inputs { filter.insert(key) }
        for key in inputs { XCTAssertTrue(filter.mayContain(key)) }
        XCTAssertTrue(filter.mayContain("codex:cafe\u{301}"))
        var saturated = StatisticsRecordMembership(wordCount: 1)
        for key in inputs { saturated.insert(key) }
        XCTAssertTrue(saturated.mayContain("not-inserted"))
        var publication = StatisticsAppendPublication(keys: Set(inputs), interned: [:], firstPaths: [:], schema: "1:0", bloomWords: 1)!
        XCTAssertNil(publication.admit(row("not-inserted"), path: "b", after: 10))
    }
    func testEarlierPathDifferentCanonicalRepresentativeDeclinesButLaterPathReusesSpelling() {
        let nfc = "caf\u{e9}-model-0123456789", nfd = "cafe\u{301}-model-0123456789"
        var earlier = StatisticsAppendPublication(keys: [], interned: [nfc: nfc], firstPaths: [nfc: "b"], schema: "1:0")!
        XCTAssertNil(earlier.admit(row(model: nfd), path: "a", after: 10))
        var later = StatisticsAppendPublication(keys: [], interned: [nfc: nfc], firstPaths: [nfc: "b"], schema: "1:0")!
        let accepted = later.admit(row(model: nfd), path: "c", after: 10)
        XCTAssertEqual(Array(accepted!.model.utf8), Array(nfc.utf8))
    }
    func testInternerSharedNamespaceAndEarlierIdenticalRepresentativeUpdatePrecedence() {
        let nfc = "caf\u{e9}-model-0123456789", nfd = "cafe\u{301}-model-0123456789"
        var publication = StatisticsAppendPublication(keys: [], interned: [nfc: nfc], firstPaths: [nfc: "z"], schema: "1:0")!
        XCTAssertNotNil(publication.admit(row("first", model: nfc), path: "a", after: 10))
        var next = row("second", model: "short"); next.project = nfd
        let accepted = publication.admit(next, path: "b", after: 10)
        XCTAssertEqual(Array(accepted!.project.utf8), Array(nfc.utf8))
    }
    func testShortStringsBypassInternerAtActualUTF8LengthThreshold() {
        var publication = StatisticsAppendPublication(keys: [], interned: [:], firstPaths: [:], schema: "1:0")!
        let a = publication.admit(row("one", model: "caf\u{e9}"), path: "a", after: 10)
        let b = publication.admit(row("two", model: "cafe\u{301}"), path: "b", after: 10)
        XCTAssertEqual(Array(a!.model.utf8), Array("caf\u{e9}".utf8))
        XCTAssertEqual(Array(b!.model.utf8), Array("cafe\u{301}".utf8))
    }
    func testMembershipAndTimestampRefusalsDoNotDropOrAdoptRecords() {
        var publication = StatisticsAppendPublication(keys: ["codex:old"], interned: [:], firstPaths: [:], schema: "1:0")!
        XCTAssertNil(publication.admit(row("old"), path: "a", after: 10))
        XCTAssertNil(publication.admit(row(), path: "a", after: 20))
        var invalid = row(); invalid.ts = .infinity
        XCTAssertNil(publication.admit(invalid, path: "a", after: 10))
        invalid = row(); invalid.source = "claude"
        XCTAssertNil(publication.admit(invalid, path: "a", after: 10))
        XCTAssertNotNil(publication.admit(row(), path: "a", after: 10))
        XCTAssertNil(publication.admit(row(), path: "b", after: 10))
    }
    func testProvenanceBudgetDeclinesCompleteGenerationOrNewClassInsteadOfEvicting() {
        let long = String(repeating: "a", count: 64)
        XCTAssertNil(StatisticsAppendPublication(keys: [], interned: [long: long], firstPaths: [long: "a"], schema: "1:0", maximumBytes: 100))
        XCTAssertNil(StatisticsAppendPublication(keys: [], interned: [long: long], firstPaths: [:], schema: "1:0"))
        var publication = StatisticsAppendPublication(keys: [], interned: [:], firstPaths: [:], schema: "1:0", maximumBytes: 100)!
        XCTAssertNil(publication.admit(row(model: long), path: "a", after: 10))
    }
    func testOriginsAreBoundedDuringCollectionAndLongerEarlierPathsRemainConservative() {
        var origins = StatisticsInternerOrigins(maximumBytes: 1000)
        for i in 0..<100 { origins.note("long-fixture-class-\(i)", representative: "long-fixture-class-\(i)", path: "a") }
        XCTAssertNil(origins.entries)
        XCTAssertLessThanOrEqual(origins.payloadBytes, 1000)
        XCTAssertNil(StatisticsAppendPublication(keys: [], origins: origins, schema: "1:0"))
        let nfc = "caf\u{e9}-model-0123456789", nfd = "cafe\u{301}-model-0123456789"
        var publication = StatisticsAppendPublication(keys: [], interned: [nfc:nfc], firstPaths: [nfc:"z"], schema:"1:0")!
        XCTAssertNotNil(publication.admit(row("first", model:nfc), path:"a-very-long-earlier-path", after:10))
        // Retaining z instead of an uncharged longer path may only reject a
        // later candidate, even though a fresh complete interner could admit it.
        XCTAssertNil(publication.admit(row("second", model:nfd), path:"b", after:10))
    }
}
