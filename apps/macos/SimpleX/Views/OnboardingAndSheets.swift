//
//  OnboardingAndSheets.swift
//  SimpleX (macOS)
//

import SwiftUI
import SimpleXChat
import UserNotifications

struct CreateProfileView: View {
    @Environment(ChatStore.self) private var store
    @State private var name = ""
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to SimpleX")
                .font(.largeTitle.weight(.semibold))
            Text("Your profile is stored only on this Mac and shared only with your contacts. SimpleX servers can't see it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Form {
                TextField("Display name", text: $name)
                    .onSubmit(create)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 380, maxHeight: 90)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Button(action: create) {
                if creating { ProgressView().controlSize(.small) } else { Text("Create Profile") }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!validName || creating)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var validName: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && validDisplayName(name.trimmingCharacters(in: .whitespaces))
    }

    private func create() {
        guard validName, !creating else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                try await store.createProfile(displayName: name.trimmingCharacters(in: .whitespaces))
            } catch {
                self.error = responseError(error)
            }
        }
    }
}

struct NewChatSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case invite = "Invite"
        case connect = "Connect"
        var id: Self { self }
    }

    @State private var mode: Mode
    @State private var link: String

    init(initialLink: String? = nil) {
        _mode = State(initialValue: initialLink == nil ? .invite : .connect)
        _link = State(initialValue: initialLink ?? "")
    }
    @State private var working = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .invite: OneTimeLinkTab()
            case .connect: connectView
            }

            if let status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var connectView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a SimpleX link or address you received.")
                .foregroundStyle(.secondary)
            TextField("https://simplex.chat/…", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            HStack {
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) { link = s }
                }
                Button {
                    connect()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
        }
    }

    private func connect() {
        guard let userId = store.currentUser?.userId else { return }
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !working else { return }
        working = true
        status = nil
        Task {
            defer { working = false }
            do {
                switch try await connectViaLink(userId: userId, link: l) {
                case .connecting:
                    try? await store.reloadChats()
                    dismiss()
                case let .alreadyConnected(chatId), let .joiningGroup(chatId):
                    try? await store.reloadChats()
                    store.selectedChatId = chatId
                    dismiss()
                case .ownLink:
                    status = String(localized: "This is your own link.")
                }
            } catch {
                status = (error as? LocalizedError)?.errorDescription ?? responseError(error)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(ChatStore.self) private var store

    var body: some View {
        Form {
            Section("Profile") {
                if let user = store.currentUser {
                    LabeledContent("Display name", value: user.displayName)
                    if !user.fullName.isEmpty {
                        LabeledContent("Full name", value: user.fullName)
                    }
                } else {
                    Text("No profile yet").foregroundStyle(.secondary)
                }
            }
            NotificationSettingsSection()
            Section("Database") {
                LabeledContent("Location") {
                    Text(getAppDatabasePath().deletingLastPathComponent().path)
                        .textSelection(.enabled)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical)
    }
}

/// Used by shared iOS types (SimplexAddress.shareAddress).
func showShareSheet(items: [Any], completed: (() -> Void)? = nil) {
    guard let window = NSApp.keyWindow, let view = window.contentView else { return }
    let picker = NSSharingServicePicker(items: items)
    picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    completed?()
}

struct NotificationSettingsSection: View {
    @State private var previewMode = ntfPreviewModeGroupDefault.get()
    @State private var status: UNAuthorizationStatus = NotificationManager.shared.authorization

    var body: some View {
        Section {
            Picker("Show in notifications", selection: $previewMode) {
                ForEach(NotificationPreviewMode.values) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .onChange(of: previewMode) { _, mode in ntfPreviewModeGroupDefault.set(mode) }
            if status == .denied {
                LabeledContent("Notifications are turned off for SimpleX in System Settings.") {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Muting and mentions-only are set per chat.")
                .foregroundStyle(.secondary)
        }
        .task {
            await NotificationManager.shared.refreshAuthorization()
            status = NotificationManager.shared.authorization
        }
    }
}
