import Foundation
import AppKit
import UniApiCore

/// Parent startup integration: after the runtime has exclusive writable
/// ownership, await migrate(runtime:) BEFORE NSHostingView/page construction
/// and BEFORE assigning the UniApiMain frame autosave name. Read-only hosts
/// must skip this call. No page mount should initiate migration.
///
/// Existing AppStorage keys immediately receive typed values. Benchmark
/// selection/resultsState consume migrated state JSON without service changes.
/// UI owners should use uniapi.switcher.engine and uniapi.rank.metric for their
/// corresponding selectors; migration never changes provider/model config.
/// The production bundle keeps app.devved.uniapi.hub. Use its actual standard
/// defaults domain so AppStorage and AppKit frame autosave see the migration;
/// a development bundle gets its own destination-bound migration journal.
@MainActor enum NativePreferencesBridge {
    static func migrate(runtime: NativeRuntime, defaults: UserDefaults = .standard,
                        destinationDomain: String? = Bundle.main.bundleIdentifier) async throws -> NativePreferenceMigrationReport {
        guard let destinationDomain else { throw NativeFailure("Native preference migration needs the application bundle domain") }
        let migration = NativePreferences(paths: runtime.paths, defaults: defaults, destinationDomain: destinationDomain)
        return try await Task.detached(priority: .utility) { try migration.migrate() }.value
    }
    /// Autosave registration alone is not a restoration request. Call this
    /// after migration and after the parent creates its owned window.
    static func restoreWindowGeometry(_ window: NSWindow) {
        _ = window.setFrameUsingName("UniApiMain")
    }
}
