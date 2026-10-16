//
//  SimpleXApp.swift
//  SimpleX (macOS)
//

import SwiftUI
import SimpleXChat

@main
struct SimpleXApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = ChatStore.shared
    @State private var showNewChat = false

    init() {
        ChatStore.shared.start()
    }

    var body: some Scene {
        Window("SimpleX", id: "main") {
            RootView(showNewChat: $showNewChat)
                .environment(store)
                .onOpenURL { url in
                    // simplex:/ links opened from other apps
                    if store.phase == .running { store.pendingConnectLink = .init(uri: url.absoluteString) }
                }
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat…") { showNewChat = true }
                    .keyboardShortcut("n")
                    .disabled(store.phase != .running)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

struct RootView: View {
    @Environment(ChatStore.self) private var store
    @Binding var showNewChat: Bool
    @State private var confirmReset = false

    var body: some View {
        switch store.phase {
        case .starting:
            ProgressView("Starting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsProfile:
            CreateProfileView()
        case .running:
            MainView(showNewChat: $showNewChat)
        case let .failed(message):
            ContentUnavailableView {
                Label("SimpleX couldn't start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                if store.canResetDatabase {
                    Button("Reset Database…", role: .destructive) { confirmReset = true }
                }
            }
            .confirmationDialog("Reset the database?", isPresented: $confirmReset) {
                Button("Delete and Start Over", role: .destructive) { store.resetDatabase() }
            } message: {
                Text("This deletes all chats, contacts and files stored by this app. This can't be undone.")
            }
        }
    }
}
