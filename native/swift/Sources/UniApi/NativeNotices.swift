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
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    NativeIcon(notice.kind == .error ? "circle-alert" : notice.kind == .success ? "circle-check" : "info", size: 14)
                        .foregroundStyle(notice.kind == .error ? Theme.failFg : notice.kind == .success ? Theme.okFg : Theme.muted)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2.5 }
                    Text(notice.text).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button { center.dismiss(notice.id) } label: { NativeIcon("x", size: 12).foregroundStyle(Theme.muted).frame(width: 18, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.plain).pointingHand().help("Dismiss").accessibilityLabel("Dismiss notification")
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(notice.kind == .error ? Theme.failFg.opacity(0.45) : Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                .opacity(notice.leaving == nil ? 1 : 0)
                .allowsHitTesting(notice.leaving == nil)
                .animation(reduced ? nil : .easeOut(duration: NativeNoticeQueue.fadeDuration), value: notice.leaving)
                .transition(.opacity)
            }
        }
        .frame(width: 340).padding(.trailing, 16).padding(.top, Theme.barHeight + 8)
        .animation(reduced ? nil : .easeOut(duration: NativeNoticeQueue.fadeDuration), value: center.queue.rows.map(\.id))
        .accessibilityLabel("Notifications")
    }
}

extension Notification.Name { static let nativeNotice = Notification.Name("UniApi.NativeNotice") }
