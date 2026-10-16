//
//  ChatStore.swift
//  SimpleX (macOS)
//
//  App state: the chat list, the open conversation, and core event handling.
//

import Foundation
import Observation
import SimpleXChat

enum AppPhase: Equatable {
    case starting
    case needsProfile
    case running
    case failed(String)
}

@MainActor
@Observable
final class ChatStore {
    static let shared = ChatStore()

    private(set) var phase: AppPhase = .starting
    private(set) var currentUser: User?
    private(set) var chats: [ChatData] = []

    var selectedChatId: ChatId? {
        didSet { if selectedChatId != oldValue { openSelectedChat() } }
    }
    /// Items of the open conversation, oldest first.
    private(set) var items: [ChatItem] = []
    private(set) var hasOlderItems = true
    private var loadingOlder = false

    var selectedChat: ChatData? {
        guard let selectedChatId else { return nil }
        return chats.first { $0.id == selectedChatId }
    }

    private var receiver: Thread?
    private var reloadTask: Task<Void, Never>?

    // MARK: Startup

    /// The Haskell runtime can only be initialized once per process.
    private nonisolated(unsafe) static var coreInitialized = false

    func start() {
        phase = .starting
        canResetDatabase = false
        Task.detached(priority: .userInitiated) {
            if !Self.coreInitialized {
                haskell_init_mac()
                registerGroupDefaults()
                Self.coreInitialized = true
            }
            if hasDatabase() && storeDBPassphraseGroupDefault.get() && kcDatabasePassword.get() == nil {
                await self.fail("The encryption key for the existing database isn't in your keychain, so it can't be opened.", canReset: true)
                return
            }
            let (_, res) = chatMigrateInit()
            switch res {
            case .ok: break
            case .errorNotADatabase:
                await self.fail("The database can't be opened. It may be encrypted with a key that's no longer available.", canReset: true)
                return
            default:
                await self.fail("Database error: \(String(describing: res))")
                return
            }
            do {
                let user = try apiGetActiveUser()
                await MainActor.run { self.currentUser = user }
                if user == nil {
                    await MainActor.run { self.phase = .needsProfile }
                } else {
                    try await self.startChat()
                }
            } catch {
                await self.fail(responseError(error))
            }
        }
    }

    func createProfile(displayName: String) async throws {
        let user = try await apiCreateActiveUser(Profile(displayName: displayName, fullName: ""))
        currentUser = user
        try await startChat()
    }

    private nonisolated func startChat() async throws {
        try setNetworkConfig(getNetCfg())
        try apiSetAppFilePaths()
        _ = try apiStartChat()
        await MainActor.run { self.startReceiver() }
        try await reloadChats()
        await MainActor.run { self.phase = .running }
    }

    private(set) var canResetDatabase = false

    private func fail(_ message: String, canReset: Bool = false) {
        logger.error("startup failed: \(message)")
        canResetDatabase = canReset
        phase = .failed(message)
    }

    /// Stops the chat and closes the database. Called off the main thread when the app quits.
    nonisolated static func shutdown(chatRunning: Bool) {
        guard hasChatCtrl() else { return }
        if chatRunning {
            do {
                let r: ChatResponse0 = try chatSendCmdSync(.apiStopChat)
                if case .chatStopped = r {} else { logger.error("apiStopChat: \(r.responseType)") }
            } catch {
                logger.error("apiStopChat: \(responseError(error))")
            }
        }
        chatCloseStore()
        logger.info("chat stopped, database closed")
    }

    /// Deletes the database, its files and keychain key, then starts over with a new database.
    func resetDatabase() {
        // Only offered when startup failed before the chat was started, so nothing is using the database.
        resetChatCtrl()
        deleteAppDatabaseAndFiles()
        start()
    }

    // MARK: Chat list

    nonisolated func reloadChats() async throws {
        guard let userId = await currentUser?.userId else { return }
        let chats = try await apiGetChats(userId: userId)
        await MainActor.run { self.chats = Self.sorted(chats) }
    }

    /// Coalesces bursts of events that need a full chat list refresh.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? await reloadChats()
        }
    }

    private static func sorted(_ chats: [ChatData]) -> [ChatData] {
        chats.sorted { $0.chatInfo.chatTs > $1.chatInfo.chatTs }
    }

    func deleteChat(_ chat: ChatData) async throws {
        try await apiDeleteChat(chat.chatInfo)
        chats.removeAll { $0.id == chat.id }
        if selectedChatId == chat.id { selectedChatId = nil }
    }

    // MARK: Conversation

    private func openSelectedChat() {
        items = []
        hasOlderItems = true
        guard let chatId = selectedChatId else { return }
        Task {
            do {
                let chat = try await apiGetChat(chatId: chatId, pagination: .last(count: ChatPagination.INITIAL_COUNT))
                guard selectedChatId == chatId else { return }
                items = chat.chatItems
                hasOlderItems = chat.chatItems.count >= ChatPagination.INITIAL_COUNT
                markRead(chatId)
            } catch {
                logger.error("apiGetChat: \(responseError(error))")
            }
        }
    }

    func loadOlderItems() {
        guard let chatId = selectedChatId, hasOlderItems, !loadingOlder, let first = items.first else { return }
        loadingOlder = true
        Task {
            defer { loadingOlder = false }
            guard let chat = try? await apiGetChat(chatId: chatId, pagination: .before(chatItemId: first.id, count: ChatPagination.PRELOAD_COUNT)),
                  selectedChatId == chatId else { return }
            let known = Set(items.map(\.id))
            items.insert(contentsOf: chat.chatItems.filter { !known.contains($0.id) }, at: 0)
            hasOlderItems = chat.chatItems.count >= ChatPagination.PRELOAD_COUNT
        }
    }

    func send(_ text: String) async throws {
        guard let chat = selectedChat else { return }
        let sent = try await apiSendText(text, to: chat.chatInfo)
        for item in sent { add(item, to: chat.chatInfo) }
    }

    private func markRead(_ chatId: ChatId) {
        guard let i = chats.firstIndex(where: { $0.id == chatId }), chats[i].chatStats.unreadCount > 0 || chats[i].chatStats.unreadChat else { return }
        let info = chats[i].chatInfo
        chats[i].chatStats = ChatStats()
        Task { try? await apiChatRead(info) }
    }

    // MARK: Core events

    private func startReceiver() {
        guard receiver == nil else { return }
        // recvSimpleXMsg blocks for up to 15s, so it gets its own thread instead of the cooperative pool.
        let thread = Thread {
            while true {
                if let evt: APIResult<ChatEvent> = recvSimpleXMsg() {
                    Task { @MainActor in ChatStore.shared.handle(evt) }
                }
            }
        }
        thread.name = "chat.simplex.mac.receiver"
        thread.qualityOfService = .userInitiated
        thread.start()
        receiver = thread
    }

    private func handle(_ res: APIResult<ChatEvent>) {
        guard case let .result(evt) = res else {
            if case let .error(e) = res { logger.error("event error: \(String(describing: e))") }
            return
        }
        switch evt {
        case let .newChatItems(user, aItems):
            guard isCurrentUser(user) else { return }
            for a in aItems { add(a.chatItem, to: a.chatInfo) }
        case let .chatItemUpdated(user, a):
            guard isCurrentUser(user) else { return }
            update(a.chatItem, in: a.chatInfo)
        case let .chatItemsStatusesUpdated(user, aItems):
            guard isCurrentUser(user) else { return }
            for a in aItems { update(a.chatItem, in: a.chatInfo) }
        case let .chatItemsDeleted(user, deletions, _):
            guard isCurrentUser(user) else { return }
            for d in deletions {
                if let to = d.toChatItem { update(to.chatItem, in: to.chatInfo) }
                else { remove(d.deletedChatItem.chatItem.id, from: d.deletedChatItem.chatInfo.id) }
            }
        case let .contactConnected(user, contact, _), let .contactUpdated(user, contact), let .contactSndReady(user, contact):
            guard isCurrentUser(user) else { return }
            updateInfo(.direct(contact: contact))
        case let .chatInfoUpdated(user, info):
            guard isCurrentUser(user) else { return }
            updateInfo(info)
        case let .groupUpdated(user, groupInfo):
            guard isCurrentUser(user) else { return }
            updateInfo(.group(groupInfo: groupInfo, groupChatScope: nil))
        case .receivedContactRequest, .contactDeletedByContact, .contactConnecting,
             .receivedGroupInvitation, .userJoinedGroup, .groupDeleted, .deletedMemberUser:
            scheduleReload()
        default:
            break
        }
    }

    private func isCurrentUser(_ user: UserRef) -> Bool {
        user.userId == currentUser?.userId
    }

    private func add(_ item: ChatItem, to info: ChatInfo) {
        if let i = chats.firstIndex(where: { $0.id == info.id }) {
            var chat = chats.remove(at: i)
            chat.chatInfo = info
            chat.chatItems = [item]
            if item.isRcvNew && selectedChatId != info.id { chat.chatStats.unreadCount += 1 }
            chats.insert(chat, at: 0)
        } else {
            scheduleReload()
        }
        if selectedChatId == info.id {
            if let j = items.lastIndex(where: { $0.id == item.id }) {
                items[j] = item
            } else {
                items.append(item)
            }
            if item.isRcvNew { markRead(info.id) }
        }
    }

    private func update(_ item: ChatItem, in info: ChatInfo) {
        if let i = chats.firstIndex(where: { $0.id == info.id }), chats[i].chatItems.last?.id == item.id {
            chats[i].chatItems = [item]
        }
        if selectedChatId == info.id, let j = items.lastIndex(where: { $0.id == item.id }) {
            items[j] = item
        }
    }

    private func remove(_ itemId: Int64, from chatId: ChatId) {
        if selectedChatId == chatId { items.removeAll { $0.id == itemId } }
    }

    private func updateInfo(_ info: ChatInfo) {
        if let i = chats.firstIndex(where: { $0.id == info.id }) {
            chats[i].chatInfo = info
        } else {
            scheduleReload()
        }
    }
}
