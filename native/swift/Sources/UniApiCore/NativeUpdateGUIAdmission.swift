import Foundation
import AppKit
import CoreGraphics
import CoreFoundation
import Darwin

/// Read-only admission metadata. A hidden accessory owner may retain AppKit's
/// main window; argv --background alone does not prove that presentation is off.
enum NativeUpdateGUIAdmission {
    enum Activation: Equatable, Sendable { case regular, accessory, prohibited, unknown }
    struct Application: Sendable {
        let pid: Int32
        let bundle: URL?, executable: URL?, identifier: String?
        let activation: Activation
    }
    struct Window: Sendable { let pid: Int32; let layer: Int?; let onScreen: Bool?; var bounds: CGRect? = nil }
    struct Snapshot: Sendable {
        let applications: [Application], windows: [Window]
        var callerPID: Int32 = getpid()
        var callerIsHeadless = true
        var displayBounds: [CGRect] = []
    }
    typealias Reader = @Sendable () throws -> Snapshot

    static func check(_ snapshot: Snapshot, application: URL, managedPID: Int32?, requireManagedMembership: Bool = true) throws {
        func path(_ value: URL?) -> String? { value.map(NativeLegacyRetirementSystem.canonical) }
        let app = path(application), executable = path(application.appendingPathComponent("Contents/MacOS/UniApiNative"))
        var managed = false, seen = Set<Int32>()
        for item in snapshot.applications {
            let relevant = item.pid == managedPID || item.identifier == "app.devved.uniapi.hub" || path(item.bundle) == app || path(item.executable) == executable
            guard relevant else { continue }
            guard item.pid > 1, seen.insert(item.pid).inserted else { throw NativeFailure("Native GUI application metadata is ambiguous") }
            if item.pid == snapshot.callerPID && snapshot.callerIsHeadless {
                guard !snapshot.windows.contains(where: { $0.pid == item.pid }) else { throw NativeFailure("The update caller owns a window") }
                continue
            }
            guard item.pid == managedPID, item.identifier == "app.devved.uniapi.hub", path(item.bundle) == app,
                  path(item.executable) == executable, item.activation == .accessory else {
                throw NativeFailure("Close the native window and any other production UniApi instance before updating")
            }
            managed = true
        }
        if requireManagedMembership && managedPID != nil && !managed { throw NativeFailure("Native GUI owner membership is unconfirmed") }
        for window in snapshot.windows where window.pid == managedPID {
            guard let layer = window.layer, let onScreen = window.onScreen else { throw NativeFailure("Native window metadata is unavailable") }
            guard !onScreen || statusGlyph(window, level: layer, displays: snapshot.displayBounds) else {
                throw NativeFailure("Close native menus, panels and windows before updating")
            }
        }
    }
    private static func statusGlyph(_ window: Window, level: Int, displays: [CGRect]) -> Bool {
        guard level == Int(CGWindowLevelForKey(.statusWindow)), let bounds = window.bounds,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }),
              (CGFloat(18)...CGFloat(256)).contains(bounds.width), (CGFloat(18)...CGFloat(40)).contains(bounds.height) else { return false }
        // NativeFanMenu uses one variable-length NSStatusItem: an 18-point
        // image plus a short temperature/RPM title. This conservative admission
        // envelope permits that glyph strip, not a general level-25 panel.
        // CG coordinates are top-left, including secondary-display origins.
        return displays.contains { screen in
            [screen.minX, screen.minY, screen.width, screen.height].allSatisfy({ $0.isFinite }) &&
            screen.width > 0 && screen.height > 0 && bounds.minY == screen.minY &&
            bounds.minX >= screen.minX && bounds.maxX <= screen.maxX
        }
    }

    /// A synchronous work barrier cannot await MainActor. Never block that actor
    /// on itself, and never reuse a cached application/window census after STOP.
    static func read() throws -> Snapshot {
        if Thread.isMainThread { return try MainActor.assumeIsolated { try collect() } }
        let box = Box(), started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { box.finish(Result { try MainActor.assumeIsolated { try collect() } }) }
        guard box.ready.wait(timeout: .now() + 0.5) == .success,
              ProcessInfo.processInfo.systemUptime - started < 0.5 else { throw NativeFailure("Native GUI admission metadata deadline expired") }
        return try box.value()
    }
    private final class Box: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0), lock = NSLock()
        private var result: Result<Snapshot, Error>?
        func finish(_ value: Result<Snapshot, Error>) { lock.withLock { result = value }; ready.signal() }
        func value() throws -> Snapshot { try lock.withLock { try result!.get() } }
    }
    static func window(_ item: [String: Any]) throws -> Window {
        guard let number = item[kCGWindowOwnerPID as String] as? NSNumber, number.doubleValue.isFinite,
              number.doubleValue > 1, number.doubleValue.rounded() == number.doubleValue, number.doubleValue <= Double(Int32.max),
              let layer = item[kCGWindowLayer as String] as? NSNumber, layer.doubleValue.isFinite,
              layer.doubleValue.rounded() == layer.doubleValue, abs(layer.doubleValue) <= Double(Int32.max) else { throw NativeFailure("Native window metadata is invalid") }
        let onScreen: Bool
        if item[kCGWindowIsOnscreen as String] == nil {
            // Pinned SDK CGWindow.h explicitly defines an absent optional key
            // as not ordered onscreen. This is not an unknown-state fallback.
            onScreen = false
        } else {
            guard let value = item[kCGWindowIsOnscreen as String] as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { throw NativeFailure("Native window visibility metadata is invalid") }
            onScreen = value.boolValue
        }
        var result = Window(pid: number.int32Value, layer: layer.intValue, onScreen: onScreen)
        if let raw = item[kCGWindowBounds as String] as? [String: Any] { result.bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) }
        return result
    }
    @MainActor private static func collect() throws -> Snapshot {
        let apps = NSWorkspace.shared.runningApplications.map { item in
            let activation: Activation
            switch item.activationPolicy { case .regular: activation = .regular; case .accessory: activation = .accessory; case .prohibited: activation = .prohibited; @unknown default: activation = .unknown }
            return Application(pid: item.processIdentifier, bundle: item.bundleURL, executable: item.executableURL, identifier: item.bundleIdentifier, activation: activation)
        }
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { throw NativeFailure("Native window census is unavailable") }
        let windows = try raw.map(window)
        let displays = try NSScreen.screens.map { screen -> CGRect in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber else { throw NativeFailure("Native status-window display metadata is unavailable") }
            let bounds = CGDisplayBounds(number.uint32Value)
            guard !bounds.isNull, !bounds.isEmpty else { throw NativeFailure("Native status-window display bounds are unavailable") }
            return bounds
        }
        return Snapshot(applications: apps, windows: windows, callerIsHeadless: NSApp == nil, displayBounds: displays)
    }
}
