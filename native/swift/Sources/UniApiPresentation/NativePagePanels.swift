import AppKit

/// The application has one retained page window. Modeless .begin panels and
/// modal pickers explicitly register against it; keyboard focus is not a
/// substitute for the originating window's ownership.
@MainActor package final class NativePagePanels {
    package static let shared = NativePagePanels()
    package weak var pageWindow: NSWindow? { didSet { configured = true; generation = UUID() } }
    private var configured = false
    private var generation = UUID()
    package struct Token { fileprivate let generation: UUID }
    package func capture() -> Token { Token(generation: generation) }
    package func isCurrent(_ token: Token) -> Bool { token.generation == generation }
    package func invalidatePresentation() {
        if let pageWindow { cancelOwnedPanels(for: pageWindow) }
        else { generation = UUID() }
    }
    fileprivate struct Admission { let id: UUID?; let lease: NativePagePanelLease }
    private final class Entry {
        weak var panel: NSWindow?
        weak var owner: NSWindow?
        let cancel: () -> Void
        let lease: NativePagePanelLease
        init(_ panel: NSWindow, owner: NSWindow, lease: NativePagePanelLease, cancel: @escaping () -> Void) {
            self.panel = panel; self.owner = owner; self.lease = lease; self.cancel = cancel
        }
    }
    private var entries: [UUID: Entry] = [:]
    fileprivate func adopt(_ panel: NSWindow, token: Token, cancel: @escaping () -> Void) -> Admission {
        let lease = NativePagePanelLease()
        guard isCurrent(token) else { lease.invalidate(); return Admission(id: nil, lease: lease) }
        guard let pageWindow else { if configured { lease.invalidate() }; return Admission(id: nil, lease: lease) }
        guard pageWindow.isVisible, !pageWindow.isMiniaturized, !NSApp.isHidden else {
            lease.invalidate(); return Admission(id: nil, lease: lease)
        }
        let id = UUID(); entries[id] = Entry(panel, owner: pageWindow, lease: lease, cancel: cancel)
        NotificationCenter.default.post(name: .nativePagePanelChanged, object: nil)
        return Admission(id: id, lease: lease)
    }
    fileprivate func finish(_ admission: Admission) -> Bool {
        if let id = admission.id { entries.removeValue(forKey: id) }
        NotificationCenter.default.post(name: .nativePagePanelChanged, object: nil)
        return admission.lease.consume()
    }
    package func hasVisiblePanel(for window: NSWindow) -> Bool {
        entries.values.contains { $0.owner === window && $0.panel.map { $0.isVisible && !$0.isMiniaturized } == true }
    }
    package func cancelOwnedPanels(for window: NSWindow) {
        generation = UUID()
        let owned = entries.filter { $0.value.owner === window }
        for (id, entry) in owned { entry.lease.invalidate(); entries.removeValue(forKey: id) }
        for entry in owned.values { entry.cancel() }
        NotificationCenter.default.post(name: .nativePagePanelChanged, object: nil)
    }
}

package extension Notification.Name {
    static let nativePagePanelChanged = Notification.Name("UniApi.NativePagePanelChanged")
}

package extension NSSavePanel {
    @MainActor func nativeBegin(token: NativePagePanels.Token? = nil, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        let admission = NativePagePanels.shared.adopt(self, token: token ?? NativePagePanels.shared.capture(), cancel: { [weak self] in self?.cancel(nil) })
        guard admission.lease.valid else { DispatchQueue.main.async { completionHandler(.cancel) }; return }
        begin { response in
            let valid = NativePagePanels.shared.finish(admission)
            completionHandler(valid ? response : .cancel)
        }
    }
    @MainActor func nativeRunModal(token: NativePagePanels.Token? = nil) -> NSApplication.ModalResponse {
        let admission = NativePagePanels.shared.adopt(self, token: token ?? NativePagePanels.shared.capture(), cancel: { [weak self] in self?.cancel(nil) })
        guard admission.lease.valid else { return .cancel }
        let response = runModal()
        return NativePagePanels.shared.finish(admission) ? response : .cancel
    }
}

package extension NSAlert {
    @MainActor func nativeRunModal() -> NSApplication.ModalResponse {
        let window = self.window
        let admission = NativePagePanels.shared.adopt(window, token: NativePagePanels.shared.capture(), cancel: { [weak window] in
            if NSApp.modalWindow === window { NSApp.abortModal() }
            window?.orderOut(nil)
        })
        guard admission.lease.valid else { return .cancel }
        let response = runModal()
        return NativePagePanels.shared.finish(admission) ? response : .cancel
    }
}
