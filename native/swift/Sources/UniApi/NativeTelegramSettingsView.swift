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

    private var status: String {
        if loadFailed { return "Unavailable" }
        if !loaded { return "Loading" }
        if saved.enabled { return validSavedCredentials ? "Ready" : "Not configured" }
        return saved.token.isEmpty && saved.chat.isEmpty ? "Not configured" : "Off"
    }

    // Match the save API's local validation; readiness does not imply delivery.
    private var validSavedCredentials: Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-")
        return !saved.token.isEmpty && saved.token.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !saved.chat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NativeSection("Telegram", detail: statusDescription) {
            HStack(alignment: .center, spacing: 12) {
                NativeStatus(text: status, tone: loadFailed ? .fail : status == "Ready" ? .ok : .idle)
                    .accessibilityLabel("Telegram status: " + status)
                Spacer()
                if loadFailed {
                    Button("Retry loading") { load(force: true) }.buttonStyle(T3Button(.outline))
                } else {
                    Button(expanded ? (draft != saved ? "Close and keep draft" : "Close") : "Configure") {
                        expanded.toggle(); showToken = false
                        if !expanded { cancelLookup() }
                    }.buttonStyle(T3Button(.outline)).disabled(!loaded)
                }
            }
            if loaded && !loadFailed && draft != saved {
                Text("Unsaved changes. The saved delivery state stays active until you save.")
                    .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.warnFg)
                    .accessibilityLabel("Unsaved Telegram changes. The saved delivery state remains active.")
            }
            if expanded && !loadFailed {
                VStack(alignment: .leading, spacing: 18) {
                    step(1, "Create a bot with BotFather in Telegram and paste its token.") {
                        HStack(spacing: 8) {
                            Group {
                                if showToken { TextField("Bot token", text: $draft.token) }
                                else { SecureField("Bot token", text: $draft.token) }
                            }.nativeField(mono: true).accessibilityLabel("Telegram bot token")
                            Button(showToken ? "Hide" : "Reveal") { showToken.toggle() }
                                .buttonStyle(T3Button(.ghost)).accessibilityLabel(showToken ? "Hide bot token" : "Reveal bot token")
                        }
                    }
                    step(2, "Open the bot in Telegram and send /start. For a group, add the bot and send a message there.") { EmptyView() }
                    step(3, "Choose the chat that receives notifications.") {
                        HStack(spacing: 8) {
                            Button(lookupMessage.isEmpty ? "Find my chats" : "Find my chats again") { findChats() }
                                .buttonStyle(T3Button(.outline)).disabled(lookupTask != nil || draft.token.isEmpty)
                            if lookupTask != nil {
                                ProgressView().controlSize(.small)
                                Button("Cancel") { cancelLookup() }.buttonStyle(T3Button(.ghost))
                            }
                        }
                        if !lookupMessage.isEmpty {
                            Text(lookupMessage).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !chats.isEmpty {
                            Picker("Destination chat", selection: $draft.chat) {
                                Text("Choose a chat").tag("")
                                if !draft.chat.isEmpty && !chats.contains(where: { $0.id == draft.chat }) {
                                    Text("Current destination").tag(draft.chat)
                                }
                                ForEach(chats) { chat in Text(chat.label + " · " + chat.id).tag(chat.id) }
                            }.frame(maxWidth: 360, alignment: .leading)
                        }
                        NativeDisclosure("Enter chat ID manually") {
                            TextField("Chat ID", text: $draft.chat).nativeField(mono: true).frame(maxWidth: 240).accessibilityLabel("Telegram chat ID")
                        }
                        if draft.token != saved.token && !draft.chat.isEmpty && draft.chat == saved.chat {
                            Text("The bot token changed. Check that the saved destination is correct for this bot before saving.")
                                .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.warnFg)
                        }
                    }
                    step(4, "Enable delivery. Saving does not send a message.") {
                        HStack(spacing: 10) {
                            T3Switch(isOn: $draft.enabled).accessibilityLabel("Enable Telegram delivery")
                            Text(draft.enabled ? "Enabled" : "Off").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Save") { save(draft) }.buttonStyle(T3Button(.primary))
                        if draft != saved {
                            Button("Discard changes") { draft = saved; showToken = false; message = "" }.buttonStyle(T3Button(.ghost))
                        }
                        Spacer()
                        Button("Disconnect") { confirmDisconnect = true }.buttonStyle(T3Button(.destructive))
                            .disabled(saved == .init() && draft == .init())
                    }.padding(.leading, 34)
                }.disabled(runtime.paths.readOnly)
                    .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                if runtime.paths.readOnly {
                    Text("Notification settings are read-only in this session.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                }
            }
            if !message.isEmpty {
                Text(message).font(Theme.ui(Theme.textXs)).foregroundStyle(loadFailed ? Theme.failFg : Theme.muted)
                    .accessibilityLabel("Telegram configuration: " + message)
            }
        }
        .confirmationDialog("Disconnect Telegram?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect and clear credentials", role: .destructive) { save(.init()) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This disables delivery and clears the saved bot token and chat ID. Unsaved changes will also be discarded.")
        }
        .onAppear { load() }
        .onDisappear { cancelLookup() }
        .onChange(of: draft.token) { _, _ in
            cancelLookup(); chats = []; lookupMessage = ""
        }
    }

    /// A numbered step: the numeral hangs in the margin, the instruction and
    /// its control share one left edge.
    private func step<Control: View>(_ number: Int, _ text: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(number)).font(Theme.num(Theme.textXs, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 22, height: 22).background(Theme.subtle, in: Circle())
            VStack(alignment: .leading, spacing: 9) {
                Text(text).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                control()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
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
        if !loaded { return "" }
        if saved.enabled { return validSavedCredentials ? "Delivery has not been tested." : "Saved credentials are incomplete or invalid." }
        if saved.token.isEmpty && saved.chat.isEmpty { return "A ping when long work finishes." }
        return "Credentials saved; delivery is off."
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
