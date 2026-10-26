import SwiftUI
import AppKit
import UniApiPresentation

private struct NativePageActiveKey: EnvironmentKey { static let defaultValue = NativePageActivation() }
private struct NativePageWork {
    let owner: NativePageWorkOwner
    let reads: NativePageReadScope?
    let suspended: @MainActor () -> Void
    @MainActor func synchronize(_ activation: NativePageActivation) -> Bool {
        owner.synchronize(activation, reads: reads, suspended: suspended)
    }
}
private struct NativePageWorkKey: EnvironmentKey { static let defaultValue: NativePageWork? = nil }
extension EnvironmentValues {
    var nativePageActivation: NativePageActivation {
        get { self[NativePageActiveKey.self] }
        set { self[NativePageActiveKey.self] = newValue }
    }
    var nativePageActive: Bool { nativePageActivation.active }
    fileprivate var nativePageWork: NativePageWork? {
        get { self[NativePageWorkKey.self] }
        set { self[NativePageWorkKey.self] = newValue }
    }
}

private struct NativePageTaskIdentity<ID: Equatable>: Equatable {
    let activation: NativePageActivation
    let id: ID
}

private struct NativePageTask<ID: Equatable>: ViewModifier {
    @Environment(\.nativePageActivation) private var activation
    @Environment(\.nativePageWork) private var work
    let id: ID
    let action: @MainActor () async -> Void
    func body(content: Content) -> some View {
        content.task(id: NativePageTaskIdentity(activation: activation, id: id)) {
            guard activation.active, !Task.isCancelled else { return }
            guard work?.synchronize(activation) != false else { return }
            await action()
        }
    }
}

private struct NativePageActivity: ViewModifier {
    @Environment(\.nativePageActivation) private var activation
    @State private var owner = NativePageWorkOwner()
    var reads: NativePageReadScope?
    var suspended: @MainActor () -> Void
    func body(content: Content) -> some View {
        content
            .environment(\.nativePageWork, NativePageWork(owner: owner, reads: reads, suspended: suspended))
            .onChange(of: activation, initial: true) { _, next in _ = owner.synchronize(next, reads: reads, suspended: suspended) }
            .onDisappear { owner.suspend(activation, reads: reads, suspended: suspended) }
    }
}

extension View {
    func nativePageTask<ID: Equatable>(id: ID, _ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(NativePageTask(id: id, action: action))
    }
    func nativePageTask(_ action: @escaping @MainActor () async -> Void) -> some View {
        nativePageTask(id: false, action)
    }
    func nativePageActivity(reads: NativePageReadScope? = nil, suspended: @escaping @MainActor () -> Void = {}) -> some View {
        modifier(NativePageActivity(reads: reads, suspended: suspended))
    }
}

/// Whole-page work follows its owning window, never keyboard focus or an
/// individual scroll clip. An attached sheet remains part of that same scope.
@MainActor final class NativeWindowActivityObserver {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var scheduled = false
    private var stopped = false
    private var observations: [Bool] = []
    private var lastObserved: Bool?
    private let presented: () -> Bool
    private let changed: (Bool) -> Void
    init(window: NSWindow, presented: @escaping () -> Bool, changed: @escaping (Bool) -> Void) {
        self.window = window; self.presented = presented; self.changed = changed
        NativePagePanels.shared.pageWindow = window
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification, .nativePagePanelChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if event.name == NSApplication.didHideNotification ||
                        event.name == NSWindow.didMiniaturizeNotification && event.object as? NSWindow === self.window {
                        self.record(false)
                    } else { self.record(self.observedActivity()) }
                    self.scheduleCheck()
                }
            })
        }
        scheduleCheck()
    }
    func scheduleCheck() {
        guard !stopped else { return }
        record(observedActivity())
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }; self.scheduled = false
            // Record edges before deferring SwiftUI publication. Coalesced
            // hide/show notifications must still advance the page generation.
            self.record(self.observedActivity())
            let values = self.observations; self.observations.removeAll()
            for value in values { self.changed(value && self.presented()) }
        }
    }
    private func record(_ active: Bool) {
        guard active != lastObserved else { return }
        lastObserved = active; observations.append(active)
    }
    private func observedActivity() -> Bool {
        guard let window else { return false }
        let sheetVisible = window.attachedSheet.map { $0.isVisible && !$0.isMiniaturized } ?? false
        return NativePageActivityPolicy.active(presented: presented(), visible: window.isVisible,
            miniaturized: window.isMiniaturized, appHidden: NSApp.isHidden,
            exposed: window.occlusionState.contains(.visible),
            ownedSheetVisible: sheetVisible || NativePagePanels.shared.hasVisiblePanel(for: window))
    }
    func stop() {
        stopped = true; observations.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
