import SwiftUI

/// The web app's Lucide glyphs, drawn as native vector paths without WebKit.
struct NativeIcon: View {
    var name: String
    var size: CGFloat
    var strokeWidth: CGFloat

    init(_ name: String, size: CGFloat = 16, strokeWidth: CGFloat = 2) {
        self.name = name; self.size = size; self.strokeWidth = strokeWidth
    }
    init(systemName: String, size: CGFloat = 14) {
        self.init(systemName, size: size)
    }

    private var resolved: String { Self.aliases[name] ?? name }
    var body: some View {
        ZStack {
            if name == "star.fill" { NativeIconShape(name: resolved).fill() }
            NativeIconShape(name: resolved, filledElements: true).fill()
            NativeIconShape(name: resolved)
                .stroke(style: StrokeStyle(lineWidth: strokeWidth * size / 24, lineCap: .round, lineJoin: .round))
        }.frame(width: size, height: size).accessibilityHidden(true)
    }

    private static let aliases: [String: String] = [
        "speedometer": "gauge", "chart.bar.xaxis": "chart-bar", "doc.text": "file-text",
        "flag.2.crossed": "swords", "arrow.triangle.branch": "git-branch",
        "chart.line.uptrend.xyaxis": "chart-line", "waveform.path.ecg": "activity",
        "battery.0percent": "battery", "battery.100percent": "battery", "battery.100percent.bolt": "battery-charging",
        "checklist": "list-checks", "gearshape": "settings", "sidebar.leading": "panel-left",
        "arrow.clockwise": "refresh-cw", "checkmark": "check", "xmark": "x",
        "exclamationmark.circle": "circle-alert", "checkmark.circle": "circle-check",
        "info.circle": "info", "key.horizontal": "key-round", "trophy.fill": "trophy",
        "star.fill": "star", "arrow.up.right": "arrow-up-right", "largecircle.fill.circle": "circle-dot",
        "folder.badge.plus": "folder-plus", "trash": "trash-2", "arrow.down": "arrow-down",
        "stop.fill": "square", "arrow.up": "arrow-up", "chevron.down": "chevron-down",
        "chevron.right": "chevron-right", "chevron.left": "chevron-left", "chevron.up": "chevron-up",
        "play.fill": "play", "checkmark.square.fill": "square-check", "doc.on.doc": "copy",
        "arrow.down.doc": "file-down", "tray": "archive", "clock.arrow.circlepath": "clock",
        "externaldrive": "database", "bolt": "zap", "folder.fill": "folder",
        "arrow.left": "arrow-left", "questionmark.circle": "circle-help",
        "bubble.left.and.bubble.right": "messages-square", "square.stack.3d.up": "layers",
        "waveform": "file-audio", "arrow.left.arrow.right": "arrow-left-right",
        "folder": "folder", "house": "house", "mic.fill": "mic", "chart.xyaxis.line": "chart-no-axes-combined",
        "chart.bar": "chart-bar"
    ]
}

private struct NativeIconShape: Shape {
    let name: String
    var filledElements = false
    func path(in rect: CGRect) -> Path {
        let original: CGPath
        if filledElements {
            guard let fill = NativeIconPaths.fills[name] else { return Path() }
            original = fill
        } else { original = NativeIconPaths.all[name] ?? NativeIconPaths.all["circle-help"]! }
        return Path(original).applying(CGAffineTransform(a: rect.width / 24, b: 0, c: 0,
                                                       d: rect.height / 24, tx: rect.minX, ty: rect.minY))
    }
}

extension Button where Label == SwiftUI.Label<Text, NativeIcon> {
    init(_ title: String, nativeIcon: String, action: @escaping () -> Void) {
        self.init(action: action) {
            SwiftUI.Label { Text(title) } icon: { NativeIcon(nativeIcon, size: 14) }
        }
    }
}
