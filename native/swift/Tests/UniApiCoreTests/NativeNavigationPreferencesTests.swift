import XCTest
@testable import UniApiCore

final class NativeNavigationPreferencesTests: XCTestCase {
    func testDefaultsPreserveHomeAndLastVisitedBehavior() {
        let settings = NativeNavigationPreferences()
        XCTAssertEqual(settings.startPage, .home)
        XCTAssertTrue(settings.restoreLastPage)
        XCTAssertTrue(settings.hiddenPages.isEmpty)
        XCTAssertTrue(settings.sidebarBadges)
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: nil,
                lastVisited: "stats",
                restoreLastPage: true
            ),
            .stats
        )
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: "speed",
                lastVisited: "stats",
                restoreLastPage: false
            ),
            .speed
        )
    }

    func testUnknownValuesFallBackWithoutLeakingIntoTheSidebar() {
        let settings = NativeNavigationPreferences(
            startPage: "unknown",
            hiddenPages: "stats,not-a-page, speed,stats, prompt"
        )
        XCTAssertEqual(settings.startPage, .home)
        XCTAssertEqual(settings.hiddenPages, [.stats, .speed])
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: "invalid",
                lastVisited: "also-invalid",
                restoreLastPage: true
            ),
            .home
        )
        XCTAssertFalse(NativeNavigationPreferences.isSidebarVisible("not-a-page", hiddenPages: ""))
    }

    func testReadOnlyPreviewWinsAndInvalidPreviewFallsThrough() {
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: "speed",
                lastVisited: "stats",
                restoreLastPage: true,
                previewPage: "arena"
            ),
            .arena
        )
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: "speed",
                lastVisited: "stats",
                restoreLastPage: true,
                previewPage: "invalid"
            ),
            .stats
        )
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: "speed",
                lastVisited: "stats",
                restoreLastPage: false,
                previewPage: "arena"
            ),
            .arena
        )
    }

    func testOnlyInstalledDestinationsCanBecomeTheInitialPage() {
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: "speed",
                lastVisited: "stats",
                restoreLastPage: true,
                installedPages: ["home", "speed", "results"]
            ),
            .speed
        )
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: "settings",
                lastVisited: "speed",
                restoreLastPage: true,
                previewPage: "stats",
                installedPages: ["home", "speed", "results"]
            ),
            .speed
        )
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: "settings",
                lastVisited: "stats",
                restoreLastPage: false,
                installedPages: ["speed", "results"]
            ),
            .speed
        )
    }

    func testFallbackUsesDeclaredPageOrderRegardlessOfInstalledOrder() {
        for installed in [["results", "speed"], ["speed", "results"], ["invalid", "results", "speed", "speed"]] {
            XCTAssertEqual(
                NativeNavigationPreferences.initialPage(
                    startPage: "settings", lastVisited: nil, restoreLastPage: false, installedPages: installed
                ),
                .speed
            )
        }
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: "invalid", lastVisited: nil, restoreLastPage: false,
                installedPages: ["results", "speed", "home"]
            ),
            .home
        )
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(
                startPage: nil, lastVisited: nil, restoreLastPage: false, installedPages: []
            ),
            .home
        )
    }

    func testAnchoredPagesCannotBeHiddenAndHiddenPagesRemainKnownDestinations() {
        let settings = NativeNavigationPreferences(hiddenPages: "home,jobs,settings,stats")
        XCTAssertEqual(settings.hiddenPages, [.stats])
        for page in NativeNavigationPreferences.anchoredPages {
            XCTAssertTrue(settings.isSidebarVisible(page), page.rawValue)
        }
        XCTAssertFalse(settings.isSidebarVisible(.stats))
        XCTAssertTrue(NativeNavigationPreferences.Page.allCases.contains(.stats))

        let unchanged = NativeNavigationPreferences.settingSidebarVisibility("settings", visible: false, in: "")
        XCTAssertEqual(unchanged, "")
        XCTAssertEqual(NativeNavigationPreferences.serializedHiddenPages([.home, .jobs, .settings, .stats]), "stats")
        // Hiding a sidebar row must not disqualify the same page at launch.
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(startPage: "stats", lastVisited: nil, restoreLastPage: false),
            .stats
        )
        XCTAssertEqual(
            NativeNavigationPreferences.initialPage(startPage: "home", lastVisited: "stats", restoreLastPage: true),
            .stats
        )
    }

    func testVisibilityEditsNormalizeAndRoundTrip() {
        let hidden = NativeNavigationPreferences.settingSidebarVisibility("fans", visible: false, in: "stats,unknown")
        XCTAssertEqual(hidden, "stats,fans")
        XCTAssertEqual(
            NativeNavigationPreferences.settingSidebarVisibility("stats", visible: true, in: hidden),
            "fans"
        )
        XCTAssertEqual(NativeNavigationPreferences.parsedHiddenPages(hidden), [.stats, .fans])
        XCTAssertEqual(
            NativeNavigationPreferences.serializedHiddenPages([.fans, .stats]),
            "stats,fans"
        )
    }
}
