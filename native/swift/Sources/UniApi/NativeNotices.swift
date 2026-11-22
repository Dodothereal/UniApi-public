import SwiftUI
import AppKit
import UniApiCore

@MainActor final class NativeNoticeCenter: ObservableObject {
    @Published private(set) var queue = NativeNoticeQueue()
    private var timer: Task<Void, Never>?
    deinit { timer?.cancel() }
    func push(_ text: String, kind: NativeNoticeKind = .info) {
        guard queue.push(text, kind: kind, now: ProcessInfo.processInfo.systemUptime) != nil else { return }
        // Announce errors immediately and other status without interrupting the
        // current VoiceOver utterance. Announcement text is never persisted.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: kind == .error ? NSAccessibilityPriorityLevel.high.rawValue : NSAccessibilityPriorityLevel.medium.rawValue])
        schedule()
    }
    func dismiss(_ id: Int) { queue.dismiss(id, now: ProcessInfo.processInfo.systemUptime); schedule() }
    private func schedule() {
        timer?.cancel()
        guard let deadline = queue.nextDeadline else { timer = nil; return }
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1e9)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.queue.advance(now: ProcessInfo.processInfo.systemUptime); self.schedule()
        }
    }
}

struct NativeNoticeHost: View {
    @ObservedObject var center: NativeNoticeCenter
    @Environment(\.nativeReducedMotion) private var reduced
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.queue.rows) { notice in
                NativeNoticeSlip(text: notice.text, kind: notice.kind) { center.dismiss(notice.id) }
                    .opacity(notice.leaving == nil ? 1 : 0)
                    .allowsHitTesting(notice.leaving == nil)
                    .animation(reduced ? nil : .easeOut(duration: NativeNoticeQueue.fadeDuration), value: notice.leaving)
                    .transition(.opacity)
            }
        }
        .frame(width: 340).padding(.trailing, 16).padding(.top, 48)
        .animation(reduced ? nil : .easeOut(duration: NativeNoticeQueue.fadeDuration), value: center.queue.rows.map(\.id))
        .accessibilityLabel("Notifications")
    }
}

/// One notice: a ruled slip on the popover ground. Its kind is the tick that
/// hangs from the top rule and the engraved word beside it, never a filled card.
private struct NativeNoticeSlip: View {
    let text: String
    let kind: NativeNoticeKind
    let dismiss: () -> Void
    @State private var hovering = false

    private var tone: Color { kind == .error ? Theme.fail : kind == .success ? Theme.ok : Theme.ink }
    private var toneText: Color { kind == .error ? Theme.failFg : kind == .success ? Theme.okFg : Theme.muted }
    private var word: String { kind == .error ? "Error" : kind == .success ? "Done" : "Notice" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                MicroLabel(word, color: toneText)
                Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.ink).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            Button(action: dismiss) {
                NativeIcon("x", size: 12, strokeWidth: 1.75)
                    .foregroundStyle(hovering ? Theme.ink : Theme.muted)
                    .frame(width: 20, height: 20)
                    .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
            .help("Dismiss notification").accessibilityLabel("Dismiss notification")
            .offset(x: 4, y: -4)
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 14).padding(.bottom, 12)
        .background(Theme.popover)
        .overlay(alignment: .topLeading) {
            // The status tick: the same mark a reading hangs from.
            ZStack(alignment: .topLeading) {
                TickScale(step: 6, major: 5, minorHeight: 2, majorHeight: 4).fill(Theme.faint)
                    .frame(width: 61, height: 4).offset(x: 20)
                tone.frame(width: 2, height: 8).offset(x: 14)
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1))
        .shadow(color: Theme.shadow, radius: 14, y: 6)
    }
}

extension Notification.Name { static let nativeNotice = Notification.Name("UniApi.NativeNotice") }
