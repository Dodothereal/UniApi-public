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
                HStack(alignment: .top, spacing: 10) {
                    NativeIcon(systemName: notice.kind == .error ? "exclamationmark.circle" : notice.kind == .success ? "checkmark.circle" : "info.circle")
                        .foregroundStyle(notice.kind == .error ? Theme.failFg : notice.kind == .success ? Theme.okFg : Theme.accent)
                    Text(notice.text).font(Theme.ui(13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Button { center.dismiss(notice.id) } label: { NativeIcon(systemName: "xmark", size: 10) }
                        .buttonStyle(.plain).help("Dismiss notification").accessibilityLabel("Dismiss notification")
                }
                .padding(12).background(Theme.popover)
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).stroke(Theme.input))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                .opacity(notice.leaving == nil ? 1 : 0)
                .allowsHitTesting(notice.leaving == nil)
                .animation(reduced ? nil : .easeOut(duration: NativeNoticeQueue.fadeDuration), value: notice.leaving)
                .transition(.opacity)
            }
        }
        .frame(width: 370).padding(.trailing, 16).padding(.top, 48)
        .animation(reduced ? nil : .easeOut(duration: NativeNoticeQueue.fadeDuration), value: center.queue.rows.map(\.id))
        .accessibilityLabel("Notifications")
    }
}

extension Notification.Name { static let nativeNotice = Notification.Name("UniApi.NativeNotice") }
