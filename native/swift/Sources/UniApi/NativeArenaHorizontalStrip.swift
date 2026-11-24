import SwiftUI
import UniApiCore

struct NativeArenaHorizontalStrip<Content: View>: View {
    @ViewBuilder let content: Content
    @Namespace private var viewport
    @Namespace private var end
    @State private var contentEnd: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.nativeMotionVisible) private var visible

    private var hasMore: Bool {
        ArenaPresentationPolicy.hasTrailingOverflow(contentEnd: Double(contentEnd), viewportWidth: Double(viewportWidth))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(viewport)).maxX } action: { contentEnd = $0 }
                    Color.clear.frame(width: 1, height: 1).id(end).accessibilityHidden(true)
                }
            }
            .coordinateSpace(name: viewport)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .overlay(alignment: .trailing) {
                if hasMore {
                    ZStack(alignment: .trailing) {
                        LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 76).allowsHitTesting(false).accessibilityHidden(true)
                        T3IconButton(system: "chevron-right", help: "Scroll to the last contestant", active: true) {
                            withAnimation(reducedMotion || !visible ? nil : NativeMotion.selection) {
                                proxy.scrollTo(end, anchor: .trailing)
                            }
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.radiusMd)
                                .strokeBorder(Theme.rule).allowsHitTesting(false)
                        }
                        .padding(.trailing, 6)
                    }
                }
            }
        }
    }
}
