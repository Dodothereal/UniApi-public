import Foundation

/// The welcome flow owns its admission and completion markers. Provider setup, sign-in,
/// downloads and hardware permissions remain explicit actions in their pages.
public enum NativeOnboardingPolicy {
    public static let version = 1
    public static let completionKey = "uniapi-onboarding-version"
    public static let startedKey = "uniapi-onboarding-started-version"
    /// Inspect the persistent domain, not registered AppStorage defaults. The
    /// migration also imports page-specific keys and the existing window frame.
    public static func hasExistingPreferences(in domain: [String: Any]) -> Bool {
        domain.keys.contains { key in
            key != completionKey && key != startedKey && (key.hasPrefix("uniapi-") || key.hasPrefix("uniapi.") || key == "NSWindow Frame UniApiMain")
        }
    }

    public static func shouldOffer(completedVersion: Int, hasExistingPreferences: Bool, hasProviders: Bool, readOnly: Bool, startedVersion: Int = 0) -> Bool {
        guard !readOnly, completedVersion < version, startedVersion <= version else { return false }
        // Record admission before the first window or live appearance choice
        // writes preferences, so an interrupted fresh setup remains resumable.
        return startedVersion == version || (!hasExistingPreferences && !hasProviders)
    }

    public static func begin(in defaults: UserDefaults) {
        defaults.set(max(version, defaults.integer(forKey: startedKey)), forKey: startedKey)
    }

    public static func finish(in defaults: UserDefaults) {
        defaults.set(max(version, defaults.integer(forKey: completionKey)), forKey: completionKey)
    }
}
