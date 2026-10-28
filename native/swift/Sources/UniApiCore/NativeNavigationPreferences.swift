import Foundation

/// Validation for preferences that affect the native shell's initial page and
/// sidebar. Values are stored as strings for compatibility with AppStorage;
/// invalid or incomplete values fall back without changing the stored domain.
public struct NativeNavigationPreferences: Equatable, Sendable {
    public enum Page: String, CaseIterable, Sendable {
        case home, speed, results, prompts, arena, switcher, code, stats
        case activity, fans, battery, transcribe, jobs, settings
    }

    public static let startPageKey = "uniapi-start-page"
    public static let restoreLastPageKey = "uniapi-restore-last-page"
    public static let sidebarHiddenKey = "uniapi-sidebar-hidden"
    public static let sidebarBadgesKey = "uniapi-sidebar-badges"
    public static let defaultStartPage: Page = .home
    public static let defaultRestoreLastPage = true
    public static let defaultSidebarBadges = true
    public static let anchoredPages: Set<Page> = [.home, .jobs, .settings]

    public let startPage: Page
    public let restoreLastPage: Bool
    public let hiddenPages: Set<Page>
    public let sidebarBadges: Bool

    public init(startPage: String = Page.home.rawValue,
                restoreLastPage: Bool = true,
                hiddenPages: String = "",
                sidebarBadges: Bool = true) {
        self.startPage = Self.parsedStartPage(startPage)
        self.restoreLastPage = restoreLastPage
        self.hiddenPages = Self.parsedHiddenPages(hiddenPages)
        self.sidebarBadges = sidebarBadges
    }

    /// The launch page follows the preview override, then the last page when
    /// restoration is enabled, and finally the configured launch page.
    public static func initialPage(startPage: String?,
                                   lastVisited: String?,
                                   restoreLastPage: Bool,
                                   previewPage: String? = nil,
                                   installedPages: [String] = Page.allCases.map(\.rawValue)) -> Page {
        let installed = Set(installedPages.compactMap(Page.init(rawValue:)))
        if let previewPage, let page = Page(rawValue: previewPage), installed.contains(page) { return page }
        if restoreLastPage, let lastVisited, let page = Page(rawValue: lastVisited), installed.contains(page) { return page }
        if let startPage, let page = Page(rawValue: startPage), installed.contains(page) { return page }
        // The installed destinations may arrive from a Set; use the declared
        // page order so the fallback does not depend on hash iteration order.
        return installed.contains(defaultStartPage) ? defaultStartPage : Page.allCases.first { installed.contains($0) } ?? defaultStartPage
    }

    public static func parsedStartPage(_ stored: String?) -> Page {
        stored.flatMap(Page.init(rawValue:)) ?? defaultStartPage
    }

    /// Hidden entries are only section pages. Home, Jobs and Settings remain
    /// anchored even when an older or manually edited value names them.
    public static func parsedHiddenPages(_ stored: String) -> Set<Page> {
        Set(stored.split(separator: ",", omittingEmptySubsequences: true).compactMap {
            Page(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }).subtracting(anchoredPages)
    }

    public static func serializedHiddenPages(_ pages: Set<Page>) -> String {
        let hidden = pages.subtracting(anchoredPages)
        return Page.allCases.filter { hidden.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    public static func settingSidebarVisibility(_ page: String,
                                                visible: Bool,
                                                in stored: String) -> String {
        var hidden = parsedHiddenPages(stored)
        guard let page = Page(rawValue: page), !anchoredPages.contains(page) else {
            return serializedHiddenPages(hidden)
        }
        if visible { hidden.remove(page) } else { hidden.insert(page) }
        return serializedHiddenPages(hidden)
    }

    public static func isSidebarVisible(_ page: String, hiddenPages stored: String) -> Bool {
        guard let page = Page(rawValue: page) else { return false }
        return anchoredPages.contains(page) || !parsedHiddenPages(stored).contains(page)
    }

    public func isSidebarVisible(_ page: Page) -> Bool {
        Self.anchoredPages.contains(page) || !hiddenPages.contains(page)
    }
}
