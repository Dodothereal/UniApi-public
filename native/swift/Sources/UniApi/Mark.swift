import SwiftUI

/// The app mark, drawn from `MarkGeometry` so it is the same shape as the
/// Dock icon. `tile: false` drops the squircle and draws the bare glyph, which
/// is what you want once it is sitting on a card that already has a border.
struct UniApiMark: View {
    var size: CGFloat
    var tile: Bool = true

    private var body_: CGFloat { tile ? size * (1 - 2 * MarkGeometry.bodyInset) : size }

    var body: some View {
        let b = body_
        ZStack {
            if tile {
                RoundedRectangle(cornerRadius: b * MarkGeometry.cornerRatio, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: MarkGeometry.tileTop),
                                                  Color(hex: MarkGeometry.tileBottom)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: b * MarkGeometry.cornerRatio, style: .continuous)
                            .strokeBorder(Color(hex: MarkGeometry.tileBorder)
                                .opacity(MarkGeometry.borderAlpha),
                                          lineWidth: max(0.5, b * MarkGeometry.borderRatio))
                    )
            }

            Capsule()
                .fill(Color(hex: MarkGeometry.spineColor))
                .frame(width: b * MarkGeometry.spineW, height: b * MarkGeometry.spineH)
                .position(x: b * (MarkGeometry.spineX + MarkGeometry.spineW / 2),
                          y: b * (MarkGeometry.spineY + MarkGeometry.spineH / 2))

            ForEach(Array(MarkGeometry.bars.enumerated()), id: \.offset) { i, bar in
                Capsule()
                    .fill(Color(hex: MarkGeometry.barColors[i % MarkGeometry.barColors.count]))
                    .frame(width: b * (bar.right - MarkGeometry.barX), height: b * MarkGeometry.barH)
                    .position(x: b * ((MarkGeometry.barX + bar.right) / 2), y: b * bar.cy)
            }
        }
        .frame(width: b, height: b)
        .frame(width: size, height: size)
        .accessibilityLabel("UniApi")
    }
}

/// Mark plus wordmark, the lockup used in the sidebar header and the top bar.
struct UniApiWordmark: View {
    var markSize: CGFloat = 18
    var textSize: CGFloat = Theme.textSm
    var color: Color = Theme.ink

    var body: some View {
        HStack(spacing: 7) {
            UniApiMark(size: markSize)
            HStack(spacing: 0) {
                Text("Uni").font(Theme.ui(textSize, weight: .bold))
                Text("Api").font(Theme.ui(textSize, weight: .regular))
            }
            .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("UniApi")
    }
}
