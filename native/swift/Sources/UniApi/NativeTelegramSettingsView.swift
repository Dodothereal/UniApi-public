import SwiftUI
import UniApiCore

struct NativeTelegramSettingsView: View {
    let runtime: NativeRuntime
    @State private var draft = NativeNotifications.Configuration()
    @State private var saved = NativeNotifications.Configuration()
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var expanded = false
    @State private var showToken = false
    @State private var message = ""
    @State private var confirmDisconnect = false
    @State private var chats: [NativeNotifications.Chat] = []
    @State private var lookupMessage = ""
    @State private var lookupTask: Task<Void, Never>?
    @State private var lookupID: UUID?
    @Environment(\.nativeReducedMotion) private var reduceMotion

    private var status: String {
        if loadFailed { return "Unavailable" }
        if !loaded { return "Loading" }
        if saved.enabled { return validSavedCredentials ? "Ready" : "Not configured" }
        return saved.token.isEmpty && saved.chat.isEmpty ? "Not configured" : "Off"
    }
    private var statusTone: Color? {
        switch status { case "Ready": return Theme.okFg; case "Unavailable": return Theme.failFg; default: return nil }
    }

    // Match the save API's local validation; readiness does not imply delivery.
    private var validSavedCredentials: Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-")
        return !saved.token.isEmpty && saved.token.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !saved.chat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var dirty: Bool { loaded && !loadFailed && draft != saved }

    var body: some View {
        Band("Telegram", spacing: 0) {
            OptionRow(title: "Delivery", detail: statusDescription, ruled: !(expanded && !loadFailed)) {
                HStack(spacing: 10) {
                    Tag(status, tone: statusTone, dot: true).accessibilityLabel("Telegram status: " + status)
                    if loadFailed {
                        Button("Retry loading", nativeIcon: "refresh-cw") { load(force: true) }
                    } else {
                        Button {
                            let change = { expanded.toggle(); showToken = false }
                            if reduceMotion { change() } else { withAnimation(.spring(duration: 0.28, bounce: 0)) { change() } }
                            if !expanded { cancelLookup() }
                        } label: {
                            HStack(spacing: 6) {
                                Text(expanded ? (draft != saved ? "Close and keep draft" : "Close") : "Configure")
                                NativeIcon("chevron-down", size: 12, strokeWidth: 1.75).rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                        }.disabled(!loaded)
                    }
                }
            }
            if dirty {
                Notice(text: "Unsaved changes. The saved delivery state above stays active; the draft is kept while Settings is open.", tone: .warn)
                    .accessibilityLabel("Unsaved Telegram changes. The saved delivery state remains active.")
                    .padding(.vertical, 8)
            }
            if expanded && !loadFailed {
                VStack(alignment: .leading, spacing: 0) {
                    form.disabled(runtime.paths.readOnly)
                    if runtime.paths.readOnly {
                        Notice(text: "Notification settings are read-only in this session.").padding(.top, 10)
                    }
                    Rule().padding(.top, 18)
                }
                .transition(.opacity)
            }
            if !message.isEmpty {
                Notice(text: message, tone: loadFailed ? .fail : .info)
                    .accessibilityLabel("Telegram configuration: " + message)
                    .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $confirmDisconnect) {
            TelegramDisconnectSheet(cancel: { confirmDisconnect = false }) {
                confirmDisconnect = false
                save(.init())
            }
        }
        .onAppear { load() }
        .onDisappear { cancelLookup() }
        .onChange(of: draft.token) { _, _ in
            cancelLookup(); chats = []; lookupMessage = ""
        }
    }

    // The four steps of connecting a bot, in the order they happen.
    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            TelegramStep(number: 1, title: "Bot token", detail: "Create a bot with BotFather in Telegram, then paste its token.") {
                HStack(spacing: 4) {
                    TelegramSecretEntry(text: $draft.token, revealed: showToken)
                    IconPress(icon: showToken ? "eye-off" : "eye", help: showToken ? "Hide bot token" : "Reveal bot token") { showToken.toggle() }
                        .padding(.trailing, -7)
                }
            }
            TelegramStep(number: 2, title: "Say hello", detail: "Open your bot in Telegram and send it /start. For a group, add the bot and send a message there.") { EmptyView() }
            TelegramStep(number: 3, title: "Destination", detail: destinationDetail) {
                HStack(spacing: 8) {
                    if lookupTask != nil {
                        Button("Cancel") { cancelLookup() }.buttonStyle(Press(.quiet))
                    } else {
                        Button(lookupMessage.isEmpty ? "Find my chats" : "Find my chats again", nativeIcon: "search") { findChats() }
                            .disabled(draft.token.isEmpty)
                    }
                    if !chats.isEmpty {
                        Pick(title: "Destination chat", selection: $draft.chat, options: chatOptions, width: 190)
                    }
                    Entry(placeholder: "Chat ID", text: $draft.chat, mono: true, width: 150)
                        .accessibilityLabel("Telegram chat ID")
                        .help("If another service uses your bot or lookup is unavailable, enter a chat ID you already know.")
                }
            }
            if draft.token != saved.token && !draft.chat.isEmpty && draft.chat == saved.chat {
                Notice(text: "The bot token changed. Check that the saved destination is correct for this bot before saving.", tone: .warn)
                    .padding(.vertical, 8)
            }
            TelegramStep(number: 4, title: "Enable delivery", detail: "Stored privately by UniApi. Saving does not send a test message.", ruled: false) {
                Flip(isOn: $draft.enabled).accessibilityLabel("Enable Telegram delivery")
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Disconnect") { confirmDisconnect = true }.buttonStyle(Press(.quiet))
                    .disabled(saved == .init() && draft == .init())
                if draft != saved {
                    Button("Discard changes") { draft = saved; showToken = false; message = "" }.buttonStyle(Press(.quiet))
                }
                Button("Save") { save(draft) }.buttonStyle(Press(draft != saved ? .primary : .secondary))
            }
            .padding(.top, 10)
        }
    }

    private var chatOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = [("", "Choose a chat")]
        if !draft.chat.isEmpty && !chats.contains(where: { $0.id == draft.chat }) {
            options.append((draft.chat, "Current destination"))
        }
        return options + chats.map { ($0.id, $0.label + " · " + $0.id) }
    }
    private var destinationDetail: String {
        lookupMessage.isEmpty ? "Find the chat for notifications, or type a chat ID you already know." : lookupMessage
    }

    private func findChats() {
        cancelLookup()
        let token = draft.token
        let id = UUID()
        lookupID = id
        chats = []
        lookupMessage = "Looking for chats..."
        lookupTask = Task {
            do {
                let found = try await NativeNotifications.findChats(token: token)
                guard !Task.isCancelled, lookupID == id else { return }
                chats = found
                lookupMessage = found.isEmpty
                    ? "No chats found. Send your bot a message and try again, or enter an ID manually."
                    : "Choose the chat that should receive notifications."
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, lookupID == id else { return }
                lookupMessage = (error as? NativeNotifications.ChatLookupError)?.localizedDescription
                    ?? "Could not find chats. Try again or enter a chat ID manually."
            }
            if lookupID == id { lookupTask = nil; lookupID = nil }
        }
    }

    private func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil; lookupID = nil
        if lookupMessage == "Looking for chats..." { lookupMessage = "Lookup cancelled." }
    }

    private var statusDescription: String {
        if loadFailed { return "Saved settings could not be read." }
        if !loaded { return "Reading saved settings." }
        if saved.enabled { return validSavedCredentials ? "Enabled with saved credentials. Delivery has not been tested." : "Saved credentials are incomplete or invalid. Update and save them." }
        if saved.token.isEmpty && saved.chat.isEmpty { return "Optional: job notifications through your own bot." }
        return "Saved credentials are present; delivery is disabled."
    }

    private func load(force: Bool = false) {
        guard force || !loaded else { return }
        do {
            let config = try NativeNotifications.configuration(home: runtime.paths.home)
            saved = config; draft = config; loadFailed = false; message = ""
        } catch {
            loadFailed = true
            message = "Could not read notification settings. Check private storage access."
        }
        loaded = true
    }

    private func save(_ config: NativeNotifications.Configuration) {
        do {
            try runtime.paths.assertWritable()
            try NativeNotifications.save(config, home: runtime.paths.home)
            cancelLookup()
            saved = config; draft = config; showToken = false
            message = config == .init() ? "Disconnected and saved." : "Saved. Delivery has not been tested."
        } catch {
            message = "Could not save. Check the bot token, chat ID and private storage access."
        }
    }
}

/// One numbered step of a procedure: the number in the margin column, what to
/// do beside it, and the control that does it on the right edge.
private struct TelegramStep<Control: View>: View {
    let number: Int
    let title: String
    let detail: String
    var ruled = true
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(String(number)).font(Theme.readout(17)).foregroundStyle(Theme.faint)
                .frame(width: 26, alignment: .leading).accessibilityHidden(true)
            SettingsRow(title: title, detail: detail, ruled: ruled, control: control)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Step \(number)")
        }
    }
}

/// `Entry` for a secret: masked until deliberately revealed.
private struct TelegramSecretEntry: View {
    @Binding var text: String
    let revealed: Bool
    @FocusState private var focused: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Group {
            if revealed { TextField("Bot token", text: $text) }
            else { SecureField("Bot token", text: $text) }
        }
        .textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.ink)
        .focused($focused).accessibilityLabel("Telegram bot token")
        .padding(.horizontal, 10).frame(width: 280, height: 30)
        .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
            .strokeBorder(focused ? Theme.signal : Theme.ruleStrong, lineWidth: 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focused)
    }
}

/// Confirms the one destructive action in Settings before anything is cleared.
private struct TelegramDisconnectSheet: View {
    let cancel: () -> Void
    let confirm: () -> Void
    @AppStorage("uniapi-theme") private var appearance = "auto"
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Disconnect Telegram?").font(Theme.display(17)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            TickRule(span: 60).padding(.top, 12)
            Text("This disables delivery and clears the saved bot token and chat ID. Unsaved changes will also be discarded.")
                .font(Theme.ui(13)).foregroundStyle(Theme.dim).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel).buttonStyle(Press(.secondary)).keyboardShortcut(.cancelAction)
                Button("Disconnect and clear credentials", action: confirm).buttonStyle(Press(.danger))
            }
            .padding(.top, 24)
        }
        .padding(24).frame(width: 440)
        .background(Theme.popover)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}
