import XCTest
@testable import UniApiCore

final class NativeThemePreferencesTests: XCTestCase {
    func testHexValidationAndCanonicalSerialization() {
        XCTAssertEqual(NativeThemePreferences.normalizeHex(" #aBc012 \n"), "ABC012")
        for invalid in ["abc", "12345678", "#12345g", "##123456", "１２３４５６", ""] {
            XCTAssertNil(NativeThemePreferences.normalizeHex(invalid))
        }
        var preferences = NativeThemePreferences()
        XCTAssertTrue(preferences.set("#abcdef", token: .accent, variant: .light))
        XCTAssertFalse(preferences.set("bad", token: .accent, variant: .light))
        XCTAssertEqual(preferences.hex(.accent, .light), "ABCDEF")
        XCTAssertEqual(NativeThemePreferences(serialized: preferences.serialized()), preferences)
        XCTAssertLessThanOrEqual(preferences.serialized().utf8.count, NativeThemePreferences.maximumBytes)
    }

    func testVariantsPresetsAndResetAreIndependent() {
        var preferences = NativeThemePreferences()
        XCTAssertNil(preferences.colorOverride(.border, .dark))
        preferences.apply(.ocean, variant: .light)
        XCTAssertEqual(preferences.hex(.background, .light), "F3F8FC")
        XCTAssertNil(preferences.colorOverride(.background, .dark))
        preferences.apply(.plum, variant: .dark)
        _ = preferences.set("123456", token: .accent, variant: .dark)
        preferences.apply(.forest, variant: .dark)
        XCTAssertEqual(preferences.hex(.accent, .dark), "63BC88")
        XCTAssertEqual(preferences.hex(.background, .light), "F3F8FC")
        preferences.reset(.light)
        XCTAssertNil(preferences.colorOverride(.background, .light))
        XCTAssertEqual(preferences.hex(.accent, .dark), "63BC88")
        preferences.apply(.original, variant: .dark)
        XCTAssertEqual(preferences, NativeThemePreferences())
    }

    func testMalformedOversizedAndPartialDocumentsFallBackSafely() {
        for document in ["not json", "[]", "{\"version\":2,\"light\":{\"accent\":\"123456\"}}", "{\"version\":true,\"light\":{\"accent\":\"123456\"}}", String(repeating: "x", count: NativeThemePreferences.maximumBytes + 1)] {
            XCTAssertEqual(NativeThemePreferences(serialized: document), NativeThemePreferences())
        }
        let partial = NativeThemePreferences(serialized: """
            {"version":1,"light":{"accent":"#aabbcc","text":"bad","unknown":"123456"},"dark":{"accent":123}}
            """)
        XCTAssertEqual(partial.colorOverride(.accent, .light), "AABBCC")
        XCTAssertNil(partial.colorOverride(.text, .light))
        XCTAssertNil(partial.colorOverride(.accent, .dark))
        XCTAssertEqual(partial.hex(.text, .light), "18181B")
    }

    func testContrastUsesSrgbLuminance() {
        XCTAssertEqual(NativeThemePreferences.contrast("000000", "FFFFFF")!, 21, accuracy: 0.001)
        XCTAssertEqual(NativeThemePreferences.contrast("FFFFFF", "FFFFFF")!, 1, accuracy: 0.001)
        XCTAssertNil(NativeThemePreferences.contrast("bad", "FFFFFF"))
    }

    func testEveryPresetCoversBothVariantsWithinStorageLimit() {
        for preset in NativeThemePreferences.Preset.allCases where preset != .original {
            var preferences = NativeThemePreferences()
            for variant in NativeThemePreferences.Variant.allCases {
                preferences.apply(preset, variant: variant)
                for token in NativeThemePreferences.Token.allCases {
                    XCTAssertNotNil(preferences.colorOverride(token, variant))
                }
            }
            XCTAssertFalse(preferences.serialized().isEmpty)
            XCTAssertEqual(NativeThemePreferences(serialized: preferences.serialized()), preferences)
        }
    }

    func testUndoPalettePreservesLaterEditsAndOtherVariant() {
        var current = NativeThemePreferences()
        _ = current.set("123456", token: .accent, variant: .light)
        let before = current
        current.apply(.ocean, variant: .light)
        let after = current
        _ = current.set("654321", token: .surface, variant: .light)
        current.apply(.plum, variant: .dark)
        current.undoPaletteChange(before: before, after: after, variant: .light)
        XCTAssertEqual(current.colorOverride(.accent, .light), "123456")
        XCTAssertEqual(current.colorOverride(.surface, .light), "654321")
        XCTAssertNil(current.colorOverride(.background, .light))
        XCTAssertEqual(current.hex(.accent, .dark), "D68AC9")
    }
}
