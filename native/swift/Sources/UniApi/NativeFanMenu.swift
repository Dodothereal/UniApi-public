import AppKit
import QuartzCore
import UniApiCore

@MainActor final class NativeFanMenu: NSObject, NSMenuDelegate {
    private let service: NativeFanService
    private let readOnly: Bool
    private let show: (Bool) -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var state: JSONValue = .null
    private var poll: Timer?, request: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var rotation: NativeFanMenuRotationOverlay?
    private var sleeping = false
    init(service: NativeFanService, readOnly: Bool, show: @escaping (Bool) -> Void) {
        self.service = service; self.readOnly = readOnly; self.show = show
        super.init()
        let glyph = NSImage(systemSymbolName: "fan", accessibilityDescription: "UniApi fan control")
        if let glyph, let button = item.button {
            // Keep the old zero-angle frame's 18-point canvas/16-point extent.
            let staticImage = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.saveGState(); defer { context.restoreGState() }
                context.translateBy(x: 9, y: 9)
                glyph.draw(in: NSRect(x: -8, y: -8, width: 16, height: 16))
                return true
            }; staticImage.isTemplate = true
            button.image = staticImage
            rotation = NativeFanMenuRotationOverlay(button: button, image: staticImage)
            if let rotation { button.addSubview(rotation) }
        } else {
            item.button?.image = glyph
        }
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self; item.menu = menu
        let notifications = NSWorkspace.shared.notificationCenter
        observers.append(notifications.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.synchronizeSpin() } })
        observers.append(notifications.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sleeping = true; self?.synchronizeSpin() } })
        observers.append(notifications.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sleeping = false; self?.refresh(); self?.synchronizeSpin() } })
        poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        if let poll { RunLoop.main.add(poll, forMode: .common) }; refresh()
    }
    func stop() {
        poll?.invalidate(); request?.cancel()
        poll = nil; request = nil
        rotation?.stop(); rotation?.removeFromSuperview(); rotation = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        NSStatusBar.system.removeStatusItem(item)
    }
    private func refresh() {
        guard request == nil, !sleeping else { return }
        request = Task { [weak self] in
            guard let self else { return }
            defer { self.request = nil }
            self.state = (try? await service.handle("status")) ?? .null
            let readings = NativeHardwareDisplayPolicies.fanMenuReadings(state)
            item.button?.title = readings.title
            item.button?.toolTip = "UniApi fan control · CPU \(readings.temperature), fastest fan \(readings.rpm) RPM"
            synchronizeSpin()
        }
    }
    private func synchronizeSpin() {
        let animate = !sleeping && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && UserDefaults.standard.string(forKey: "uniapi-motion") != "reduced" && NativeHardwareDisplayPolicies.fanMenuReadings(state).spinning
        rotation?.setSpinning(animate)
    }
    func menuWillOpen(_ menu: NSMenu) { rotation?.redraw() }
    func menuDidClose(_ menu: NSMenu) { rotation?.redraw() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func label(_ text: String) { menu.addItem(withTitle: text, action: nil, keyEquivalent: "").isEnabled = false }
        label("UniApi · Fan Control")
        let fans = state["snapshot"]["fans"].array
        if fans.isEmpty { label("Waiting for live readings") }
        for fan in fans { label("Fan \(fan["id"].int + 1)    \(Int(fan["actual"].double).formatted()) RPM") }
        if !state["control"]["until"].isNull {
            let seconds = max(0, Int(state["control"]["until"].double / 1000 - Date().timeIntervalSince1970))
            label(String(format: "Automatic in %d:%02d", seconds / 60, seconds % 60))
        }
        menu.addItem(.separator())
        for (title, mode) in [("Automatic", "automatic"), ("Cooler", "cooler"), ("Boost for 5 minutes", "boost")] {
            let entry = menu.addItem(withTitle: title, action: #selector(changeMode(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = mode
            entry.isEnabled = !readOnly && state["enabled"].bool && !state["busy"].bool && request == nil
            entry.state = state["control"]["mode"].string == mode ? .on : .off
        }
        if !state["error"].string.isEmpty { menu.addItem(.separator()); label(state["error"].string) }
        menu.addItem(.separator())
        let fansEntry = menu.addItem(withTitle: "Open Fan Control…", action: #selector(openFans), keyEquivalent: ""); fansEntry.target = self
        let app = menu.addItem(withTitle: "Show UniApi", action: #selector(showApp), keyEquivalent: ""); app.target = self
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit UniApi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    @objc private func changeMode(_ sender: NSMenuItem) {
        guard !readOnly, let mode = sender.representedObject as? String, request == nil else { return }
        request = Task { [weak self] in
            guard let self else { return }; defer { self.request = nil }
            do { state = try await service.handle("control", input: mode == "boost" ? ["command": "boost", "duration": 300] : ["command": .string(mode)]) }
            catch { let alert = NSAlert(); alert.messageText = "Fan control"; alert.informativeText = error.localizedDescription; alert.runModal() }
        }
    }
    @objc private func openFans() { show(true) }
    @objc private func showApp() { show(false) }
}

/// The real status button retains text, hit testing, menu tracking and its image
/// slot. Only the template glyph's compositor layer turns between UI events.
@MainActor private final class NativeFanMenuRotationOverlay: NSView {
    private weak var button: NSStatusBarButton?
    private let image: NSImage
    private let placeholder: NSImage
    private let glyph: NativeFanMenuRotationGlyph
    private var spinning = false

    init(button: NSStatusBarButton, image: NSImage) {
        self.button = button; self.image = image
        let placeholder = NSImage(size: image.size, flipped: false) { _ in true }
        placeholder.isTemplate = true
        placeholder.accessibilityDescription = image.accessibilityDescription
        self.placeholder = placeholder
        glyph = NativeFanMenuRotationGlyph(button: button, image: image)
        super.init(frame: button.bounds)
        autoresizingMask = [.width, .height]
        addSubview(glyph)
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        if let button, let cell = button.cell {
            glyph.frame = convert(cell.imageRect(forBounds: button.bounds), from: button)
        }
    }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); needsLayout = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); redraw() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); redraw() }

    func setSpinning(_ value: Bool) {
        if value != spinning {
            spinning = value
            button?.image = value ? placeholder : image
            isHidden = !value
            glyph.setSpinning(value)
        }
        needsLayout = true
    }
    func redraw() { glyph.needsDisplay = true }
    func stop() { setSpinning(false); glyph.stop() }
}

@MainActor private final class NativeFanMenuRotationGlyph: NSView {
    private weak var button: NSStatusBarButton?
    private let image: NSImage
    private let rotor = CALayer()
    private var renderer: NativeFanRotationRenderer!

    init(button: NSStatusBarButton, image: NSImage) {
        self.button = button; self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer!.addSublayer(rotor)
        renderer = NativeFanRotationRenderer(layer: rotor, clockwise: false)
        needsDisplay = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override var allowsVibrancy: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }
    override func updateLayer() {
        guard let renderer else { return }
        let scale = window?.backingScaleFactor ?? 2
        renderer.layout(in: bounds, contentsScale: scale)
        let raster = NativeFanLayerImage.rasterize(bounds: bounds, scale: scale, appearance: effectiveAppearance, draw: drawGlyph)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rotor.contents = raster
        CATransaction.commit()
    }
    private func drawGlyph(_ context: CGContext) {
        guard let button, let cell = button.cell as? NSButtonCell,
              NSGraphicsContext.current != nil else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let origin = convert(NSPoint.zero, from: button)
        let x = convert(NSPoint(x: 1, y: 0), from: button), y = convert(NSPoint(x: 0, y: 1), from: button)
        context.concatenate(CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                             c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: button.isFlipped)
        cell.drawImage(image, withFrame: cell.imageRect(forBounds: button.bounds), in: button)
    }
    func setSpinning(_ value: Bool) {
        // A visual-rate adapter only: 1000 maps exactly to the menu's fixed
        // 0.4 rev/s. It never represents or replaces hardware telemetry.
        renderer.update(rpm: 1000, reduceMotion: false, visible: value)
    }
    func stop() { renderer.stop() }
}

extension Notification.Name { static let nativeNavigation = Notification.Name("UniApi.NativeNavigation") }
