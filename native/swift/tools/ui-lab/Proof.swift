import AppKit
import SwiftUI

// Diagnostic content only. This executable never constructs UniApi services.
private struct CaptureContent: View {
    @State private var enabled = true
    @State private var text = "Private diagnostic content"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Native capture test").font(.system(size: 20, weight: .semibold))
            Text("Actual SwiftUI controls in an unordered NSHostingView.").foregroundStyle(.secondary)
            Button("Example button") {}
            Toggle("Example toggle", isOn: $enabled)
            TextField("Text", text: $text).textFieldStyle(.roundedBorder)
            Text("No desktop input, application activation or system panels.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 640, height: 300, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)).foregroundStyle(.primary)
    }
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private final class CaptureDelegate: NSObject, NSApplicationDelegate {
    let output: URL
    var panel: CapturePanel!
    var host: NSHostingView<AnyView>!
    var samples: [[String: Any]] = []
    var activated = false
    var observer: NSObjectProtocol?
    init(output: URL) { self.output = output }

    func sample(_ label: String) throws {
        let intersects = NSScreen.screens.contains { $0.frame.intersects(panel.frame) }
        let ownFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let quiet = !intersects && !panel.isVisible && !panel.isKeyWindow && !panel.isMainWindow
            && !NSApp.isActive && !ownFrontmost && !activated
        samples.append(["label": label, "intersectsScreen": intersects,
                        "visible": panel.isVisible, "key": panel.isKeyWindow,
                        "main": panel.isMainWindow, "ownAppActive": NSApp.isActive,
                        "frontmostIsOwn": ownFrontmost, "quiet": quiet])
        guard quiet else { throw NSError(domain: "Capture.NotQuiet", code: 1) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.activated = true }
            }
        let x = (NSScreen.screens.map { $0.frame.minX }.min() ?? 0) - 10_000
        let y = (NSScreen.screens.map { $0.frame.minY }.min() ?? 0) - 10_000
        panel = CapturePanel(contentRect: NSRect(x: x, y: y, width: 640, height: 300),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        host = NSHostingView(rootView: AnyView(CaptureContent().environment(\.colorScheme, .dark)))
        panel.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        // Deliberately no order/activate call. An unordered host is sufficient
        // for this bitmap case; semantic/system-input coverage is separate.
        Task { await captureBoth() }
    }

    func captureBoth() async {
        var cases: [[String: Any]] = []
        do {
            try sample("created-unordered")
            for (name, scheme, appearance) in [("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
                                                ("light", ColorScheme.light, NSAppearance.Name.aqua)] {
                panel.appearance = NSAppearance(named: appearance)
                host.rootView = AnyView(CaptureContent().environment(\.colorScheme, scheme))
                try await Task.sleep(nanoseconds: 250_000_000)
                try sample("before-" + name)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw NSError(domain: "Capture.Bitmap", code: 1)
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "Capture.PNG", code: 1)
                }
                try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
                try sample("after-" + name)
                cases.append(["id": "proof-" + name, "label": "Native controls / " + name,
                              "image": name + ".png", "width": bitmap.pixelsWide,
                              "height": bitmap.pixelsHigh, "viewportWidth": 640, "appearance": name])
            }
            try writeJSON(["version": 1, "cases": cases], name: "manifest.json")
            try writeJSON(["kind": "unordered-native-bitmap-proof", "quiet": true,
                           "pid": ProcessInfo.processInfo.processIdentifier, "samples": samples,
                           "inputActions": 0, "serviceInstances": 0,
                           "limits": "Sampled placement/state and bitmap output only; no semantic input, system panels, compositor or application parity proof."], name: "report.json")
            finish(0)
        } catch {
            try? writeJSON(["quiet": false, "error": String(describing: error), "samples": samples], name: "report.json")
            finish(1)
        }
    }

    func writeJSON(_ value: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name), options: .atomic)
    }
    func finish(_ code: Int32) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        panel?.close()
        NSApp.stop(nil)
        exit(code)
    }
}

@main private struct CaptureMain {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        let app = NSApplication.shared
        guard app.setActivationPolicy(.accessory) else { exit(65) }
        let delegate = CaptureDelegate(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
