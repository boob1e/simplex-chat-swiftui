//
//  MainView.swift
//  SimpleX (macOS)
//

import SwiftUI
import SimpleXChat

struct MainView: View {
    @Environment(ChatStore.self) private var store
    @Binding var showNewChat: Bool

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            ChatListView(selection: $store.selectedChatId)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { store.showProfile = true } label: {
                            if let user = store.currentUser {
                                AvatarView(image: user.image, name: user.displayName, size: 22)
                            } else {
                                Image(systemName: "person.crop.circle")
                            }
                        }
                        .help("Your profile and SimpleX address (⇧⌘P)")
                    }
                    ToolbarItem {
                        Menu {
                            Button("New Chat…") { showNewChat = true }
                            Button("New Group…") { store.showNewGroup = true }
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        } primaryAction: {
                            showNewChat = true
                        }
                        .help("New chat (⌘N) or group (⇧⌘N)")
                    }
                }
        } detail: {
            if let chat = store.selectedChat {
                ConversationView(chat: chat)
                    .id(chat.id)
            } else {
                ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Choose a conversation from the sidebar."))
            }
        }
        .modifier(ClearChatConfirmation())
        .sheet(isPresented: $showNewChat) {
            NewChatSheet()
        }
        .sheet(isPresented: $store.showNewGroup) {
            NewGroupSheet()
        }
        .sheet(isPresented: $store.showGroupInfo) {
            if case let .group(groupInfo, _) = store.selectedChat?.chatInfo {
                GroupInfoSheet(groupId: groupInfo.groupId)
            }
        }
        .sheet(isPresented: $store.showProfile) {
            ProfileView()
        }
        .sheet(item: $store.pendingConnectLink) { link in
            NewChatSheet(initialLink: link.uri)
        }
    }
}
