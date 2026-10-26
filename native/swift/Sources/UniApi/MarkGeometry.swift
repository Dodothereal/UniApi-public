import CoreGraphics

// The UniApi mark, as pure numbers.
//
// A vertical spine with three tracks of different lengths running off it. Read
// left to right that is one endpoint fanning out to every provider you hold a
// key for - the shim; read right to left it is the ranking bars the Results
// page draws - the benchmark. Both halves of the app in one glyph, and at 16px
// it still resolves as three lines of different lengths against a stem.
//
// Every value is a FRACTION, so the same geometry backs the SwiftUI view in
// Mark.swift and the .icns renderer in tools/icon. Change it here or the two
// drift apart.

enum MarkGeometry {
    // ---- tile ------------------------------------------------------------
    //
    // macOS's icon grid wants the squircle at 824 of a 1024 canvas, with the
    // rest left transparent for the system's own shadow.

    static let bodyInset: CGFloat = 100.0 / 1024.0     // per side, of the canvas
    static let cornerRatio: CGFloat = 185.0 / 824.0    // of the body
    static let borderRatio: CGFloat = 2.5 / 824.0

    // ---- glyph -----------------------------------------------------------
    //
    // Fractions of the BODY, not the canvas. The spine overhangs the outermost
    // tracks by ~0.05 top and bottom so it reads as an axis they hang off,
    // rather than as a fourth bar.

    static let spineX: CGFloat = 0.145
    static let spineW: CGFloat = 0.085
    static let spineY: CGFloat = 0.195
    static let spineH: CGFloat = 0.610

    static let barX: CGFloat = 0.285                   // shared left edge
    /// Deliberately fat: three thin bars separated by thin gaps turn into one
    /// grey smudge at the 16pt stop, and 16pt is the Finder list.
    static let barH: CGFloat = 0.110

    /// centre-y and right edge of each track, longest (the winner) first.
    static let bars: [(cy: CGFloat, right: CGFloat)] = [
        (0.295, 0.885),
        (0.500, 0.705),
        (0.705, 0.545),
    ]

    // ---- colors ----------------------------------------------------------

    static let tileTop: UInt32    = 0x16181D
    static let tileBottom: UInt32 = 0x0A0B0E
    static let tileBorder: UInt32 = 0xFFFFFF
    static let borderAlpha: CGFloat = 0.10
    static let spineColor: UInt32 = 0xF2F5FA           // Theme.ink, near enough

    /// Theme.pairPalette[0], Theme.accent, then a dimmed accent - the longest
    /// track is also the brightest, which is what makes it read as a winner.
    static let barColors: [UInt32] = [0x51A2FF, 0x346BF1, 0x3B5488]

    static func rgb(_ hex: UInt32) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255.0,
         CGFloat((hex >> 8) & 0xFF) / 255.0,
         CGFloat(hex & 0xFF) / 255.0)
    }
}
