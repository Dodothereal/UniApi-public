import Foundation
import XCTest
@testable import UniApiCore

final class NativeOnboardingPolicyTests: XCTestCase {
    func testOnlyAnUnconfiguredWritableFirstLaunchOffersWelcome() {
        XCTAssertTrue(NativeOnboardingPolicy.shouldOffer(completedVersion: 0, hasExistingPreferences: false, hasProviders: false, readOnly: false))
        for completed in [1, 2, Int.max] {
            XCTAssertFalse(NativeOnboardingPolicy.shouldOffer(completedVersion: completed, hasExistingPreferences: false, hasProviders: false, readOnly: false))
        }
        XCTAssertFalse(NativeOnboardingPolicy.shouldOffer(completedVersion: 0, hasExistingPreferences: true, hasProviders: false, readOnly: false))
        XCTAssertFalse(NativeOnboardingPolicy.shouldOffer(completedVersion: 0, hasExistingPreferences: false, hasProviders: true, readOnly: false))
        XCTAssertFalse(NativeOnboardingPolicy.shouldOffer(completedVersion: 0, hasExistingPreferences: false, hasProviders: false, readOnly: true))
    }

    func testPersistentPreferencesRecognizeMigratedAndPageSpecificSettings() {
        XCTAssertFalse(NativeOnboardingPolicy.hasExistingPreferences(in: [:]))
        XCTAssertFalse(NativeOnboardingPolicy.hasExistingPreferences(in: [NativeOnboardingPolicy.completionKey: 0, "AppleLanguages": ["en"]]))
        for key in ["uniapi-theme", "uniapi-motion", "uniapi.stats.source", "uniapi.fans.duration", "NSWindow Frame UniApiMain"] {
            XCTAssertTrue(NativeOnboardingPolicy.hasExistingPreferences(in: [key: "value"]), key)
        }
    }

    func testBackAndNextStayInsideTheActualFourStepFlow() {
        XCTAssertEqual(NativeOnboardingStep.welcome.previous, .welcome)
        XCTAssertEqual(NativeOnboardingStep.ready.next, .ready)
        var step = NativeOnboardingStep.welcome
        var visited = [step]
        while step != .ready { step = step.next; visited.append(step) }
        XCTAssertEqual(visited, NativeOnboardingStep.allCases)
        while step != .welcome { step = step.previous }
        XCTAssertEqual(step, .welcome)
    }

    func testInterruptedFreshSetupSurvivesItsOwnPreferenceWrites() throws {
        let suite = "onboarding-resume-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        NativeOnboardingPolicy.begin(in: defaults)
        defaults.set("dark", forKey: "uniapi-theme")
        defaults.set("saved-frame", forKey: "NSWindow Frame UniApiMain")
        func offer(readOnly: Bool = false) -> Bool {
            NativeOnboardingPolicy.shouldOffer(
                completedVersion: defaults.integer(forKey: NativeOnboardingPolicy.completionKey),
                hasExistingPreferences: NativeOnboardingPolicy.hasExistingPreferences(in: defaults.persistentDomain(forName: suite) ?? [:]),
                hasProviders: false, readOnly: readOnly,
                startedVersion: defaults.integer(forKey: NativeOnboardingPolicy.startedKey))
        }
        XCTAssertTrue(offer())
        XCTAssertFalse(offer(readOnly: true))
        NativeOnboardingPolicy.finish(in: defaults)
        XCTAssertFalse(offer())
        XCTAssertEqual(defaults.string(forKey: "uniapi-theme"), "dark")
    }

    func testFutureStartedMarkerIsPreservedWithoutStartingAnOlderGuide() throws {
        let suite = "onboarding-future-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(7, forKey: NativeOnboardingPolicy.startedKey)
        NativeOnboardingPolicy.begin(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: NativeOnboardingPolicy.startedKey), 7)
        XCTAssertFalse(NativeOnboardingPolicy.shouldOffer(completedVersion: 0, hasExistingPreferences: false, hasProviders: false, readOnly: false, startedVersion: 7))
        XCTAssertFalse(NativeOnboardingPolicy.hasExistingPreferences(in: [NativeOnboardingPolicy.startedKey: 1]))
    }

    func testFinishOrSkipWritesOnlyCompletionAndPreservesFutureVersion() throws {
        let suite = "onboarding-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "uniapi-theme")
        defaults.set("operator-model", forKey: "model")
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        NativeOnboardingPolicy.finish(in: defaults)
        var expected = before; expected[NativeOnboardingPolicy.completionKey] = NativeOnboardingPolicy.version
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, expected as NSDictionary)
        defaults.set(7, forKey: NativeOnboardingPolicy.completionKey)
        NativeOnboardingPolicy.finish(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: NativeOnboardingPolicy.completionKey), 7)
    }
}
