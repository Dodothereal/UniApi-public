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
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Telegram notifications")
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status).font(Theme.ui(13, weight: .medium)).accessibilityLabel("Telegram status: " + status)
                    Text(statusDescription).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
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
                Text("Unsaved changes — the saved delivery state above remains active. The draft is kept while Settings stays open; save it to retain it.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.warnFg)
                    .accessibilityLabel("Unsaved Telegram changes. The saved delivery state remains active.")
            }
            if expanded && !loadFailed {
                VStack(alignment: .leading, spacing: 14) {
                    Text("1. Create a bot with BotFather in Telegram, then paste its token here.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bot token").font(Theme.ui(12, weight: .medium))
                        HStack(spacing: 8) {
                            Group {
                                if showToken { TextField("Bot token", text: $draft.token) }
                                else { SecureField("Bot token", text: $draft.token) }
                            }.textFieldStyle(.roundedBorder).accessibilityLabel("Telegram bot token")
                            Button(showToken ? "Hide" : "Reveal") { showToken.toggle() }
                                .buttonStyle(T3Button(.ghost)).accessibilityLabel(showToken ? "Hide bot token" : "Reveal bot token")
                        }
                    }
                    Text("2. Open your bot in Telegram and send it /start. For a group, add the bot and send a message there.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. Find and choose the chat for notifications.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        HStack {
                            Button(lookupMessage.isEmpty ? "Find my chats" : "Find my chats again") { findChats() }
                                .buttonStyle(T3Button(.outline)).disabled(lookupTask != nil || draft.token.isEmpty)
                            if lookupTask != nil {
                                ProgressView().controlSize(.small)
                                Button("Cancel") { cancelLookup() }.buttonStyle(T3Button(.ghost))
                            }
                        }
                        if !lookupMessage.isEmpty {
                            Text(lookupMessage).font(Theme.ui(11)).foregroundStyle(Theme.muted)
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
                        DisclosureGroup("Enter chat ID manually") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("If another service uses your bot or lookup is unavailable, enter a chat ID you already know.")
                                    .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                                TextField("Chat ID", text: $draft.chat).textFieldStyle(.roundedBorder).accessibilityLabel("Telegram chat ID")
                            }.padding(.top, 8)
                        }.font(Theme.ui(12))
                    }
                    if draft.token != saved.token && !draft.chat.isEmpty && draft.chat == saved.chat {
                        Text("The bot token changed. Check that the saved destination is correct for this bot before saving.")
                            .font(Theme.ui(11)).foregroundStyle(Theme.warnFg)
                    }
                    SettingRow(title: "4. Enable delivery", desc: "Choose a chat, then enable and save. No test message is sent.") {
                        T3Switch(isOn: $draft.enabled).accessibilityLabel("Enable Telegram delivery")
                    }
                    Text("Credentials are stored privately by UniApi. Saving does not send a message.")
                        .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Button("Save") { save(draft) }.buttonStyle(T3Button(.primary))
                        Button("Disconnect") { confirmDisconnect = true }.buttonStyle(T3Button(.ghost))
                            .disabled(saved == .init() && draft == .init())
                        if draft != saved {
                            Button("Discard changes") { draft = saved; showToken = false; message = "" }.buttonStyle(T3Button(.ghost))
                        }
                    }
                }.disabled(runtime.paths.readOnly)
                if runtime.paths.readOnly {
                    Text("Notification settings are read-only in this session.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
            }
            if !message.isEmpty {
                Text(message).font(Theme.ui(12)).foregroundStyle(loadFailed ? Theme.failFg : Theme.muted)
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
        if saved.token.isEmpty && saved.chat.isEmpty { return "Optional delivery is not set up." }
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
