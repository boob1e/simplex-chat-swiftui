//
//  CoreAPI.swift
//  SimpleX (macOS)
//
//  Thin async layer over the Haskell core. Commands and responses are the
//  same types the iOS app uses (apps/ios/Shared/Model/AppAPITypes.swift).
//

import Foundation
import OSLog
import SimpleXChat

let logger = Logger(subsystem: "chat.simplex.mac", category: "core")

/// All core calls block, so they run off the main thread on this queue.
private let coreQueue = DispatchQueue(label: "chat.simplex.mac.core", qos: .userInitiated, attributes: .concurrent)

func chatApiSendCmdSync<R: ChatAPIResult>(_ cmd: ChatCommand, ctrl: chat_ctrl? = nil) -> APIResult<R> {
    let r: APIResult<R> = sendSimpleXCmd(cmd, ctrl)
    if case let .invalid(type, json) = r {
        logger.error("\(cmd.cmdType): invalid response \(type): \(dataToString(json))")
    }
    return r
}

func chatSendCmdSync<R: ChatAPIResult>(_ cmd: ChatCommand, ctrl: chat_ctrl? = nil) throws -> R {
    try apiResult(chatApiSendCmdSync(cmd, ctrl: ctrl))
}

func chatApiSendCmd<R: ChatAPIResult>(_ cmd: ChatCommand) async -> APIResult<R> {
    await withCheckedContinuation { cont in
        coreQueue.async { cont.resume(returning: chatApiSendCmdSync(cmd)) }
    }
}

func chatSendCmd<R: ChatAPIResult>(_ cmd: ChatCommand) async throws -> R {
    try apiResult(await chatApiSendCmd(cmd))
}

func apiResult<R: ChatAPIResult>(_ res: APIResult<R>) throws -> R {
    switch res {
    case let .result(r): return r
    case let .error(e): throw e
    case let .invalid(type, _): throw ChatError.unexpectedResult(type: type)
    }
}

private func sendCommandOkResp(_ cmd: ChatCommand) async throws {
    let r: ChatResponse2 = try await chatSendCmd(cmd)
    if case .cmdOk = r { return }
    throw r.unexpected
}

// MARK: - Lifecycle

func apiGetActiveUser() throws -> User? {
    let r: APIResult<ChatResponse0> = chatApiSendCmdSync(.showActiveUser)
    switch r {
    case let .result(.activeUser(user)): return user
    case .error(.error(.noActiveUser)): return nil
    default: throw r.unexpected
    }
}

func apiCreateActiveUser(_ p: Profile) async throws -> User {
    let r: ChatResponse0 = try await chatSendCmd(.createActiveUser(profile: p, pastTimestamp: false))
    if case let .activeUser(user) = r { return user }
    throw r.unexpected
}

func apiStartChat() throws -> Bool {
    let r: ChatResponse0 = try chatSendCmdSync(.startChat(mainApp: true, enableSndFiles: true))
    switch r {
    case .chatStarted: return true
    case .chatRunning: return false
    default: throw r.unexpected
    }
}

func apiSetAppFilePaths() throws {
    let fm = FileManager.default
    for dir in [getAppFilesDirectory(), getTempFilesDirectory(), getWallpaperDirectory()] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let r: ChatResponse2 = try chatSendCmdSync(.apiSetAppFilePaths(
        filesFolder: getAppFilesDirectory().path,
        tempFolder: getTempFilesDirectory().path,
        assetsFolder: getWallpaperDirectory().deletingLastPathComponent().path
    ))
    if case .cmdOk = r { return }
    throw r.unexpected
}

func setNetworkConfig(_ cfg: NetCfg) throws {
    let r: ChatResponse2 = try chatSendCmdSync(.apiSetNetworkConfig(networkConfig: cfg))
    if case .cmdOk = r { return }
    throw r.unexpected
}

// MARK: - Chats

func apiGetChats(userId: Int64) async throws -> [ChatData] {
    let r: ChatResponse0 = try await chatSendCmd(.apiGetChats(userId: userId))
    if case let .apiChats(_, chats) = r { return chats }
    throw r.unexpected
}

func apiGetChat(chatId: ChatId, pagination: ChatPagination) async throws -> ChatData {
    let r: ChatResponse0 = try await chatSendCmd(.apiGetChat(chatId: chatId, scope: nil, contentTag: nil, pagination: pagination, search: ""))
    if case let .apiChat(_, chat, _) = r { return chat }
    throw r.unexpected
}

func apiSendText(_ text: String, to chat: ChatInfo, quotedItemId: Int64? = nil) async throws -> [ChatItem] {
    let cmd: ChatCommand = .apiSendMessages(
        type: chat.chatType, id: chat.apiId, scope: nil, sendAsGroup: false, live: false, ttl: nil, sign: false,
        composedMessages: [ComposedMessage(quotedItemId: quotedItemId, msgContent: .text(text))]
    )
    let r: ChatResponse1 = try await chatSendCmd(cmd)
    if case let .newChatItems(_, items) = r { return items.map(\.chatItem) }
    throw r.unexpected
}

func apiChatRead(_ chat: ChatInfo) async throws {
    try await sendCommandOkResp(.apiChatRead(type: chat.chatType, id: chat.apiId, scope: nil))
}

func apiDeleteChat(_ chat: ChatInfo) async throws {
    let r: ChatResponse1 = try await chatSendCmd(.apiDeleteChat(type: chat.chatType, id: chat.apiId, chatDeleteMode: .full(notify: true)))
    switch r {
    case .contactDeleted, .contactConnectionDeleted, .groupDeletedUser, .contactRequestRejected: return
    default: throw r.unexpected
    }
}

// MARK: - Connecting

func apiAddContact(userId: Int64) async throws -> (CreatedConnLink, PendingContactConnection) {
    let r: ChatResponse1 = try await chatSendCmd(.apiAddContact(userId: userId, incognito: false))
    if case let .invitation(_, link, connection) = r { return (link, connection) }
    throw r.unexpected
}

enum ConnectResult {
    case connecting
    case alreadyConnected(Contact)
    case ownLink
}

/// Resolves a SimpleX link and connects to it the same way the iOS app does for contacts.
func connectViaLink(userId: Int64, link: String) async throws -> ConnectResult {
    let r: ChatResponse1 = try await chatSendCmd(.apiConnectPlan(userId: userId, connLink: link, resolveMode: .unknown, linkOwnerSig: nil))
    guard case let .connectionPlan(_, connLink, _, _, plan) = r else { throw r.unexpected }
    let contactData: ContactShortLinkData?
    switch plan {
    case let .invitationLink(.ok(data, _)): contactData = data
    case let .contactAddress(.ok(data, _)): contactData = data
    case .invitationLink(.ownLink), .contactAddress(.ownLink): return .ownLink
    case let .invitationLink(.known(contact)), let .contactAddress(.known(contact)): return .alreadyConnected(contact)
    case .invitationLink(.connecting), .contactAddress(.connectingConfirmReconnect), .contactAddress(.connectingProhibit): return .connecting
    case .groupLink: throw ConnectError.groupsNotSupported
    case let .error(e): throw e
    default: return .connecting
    }
    if let contactData {
        let p: ChatResponse1 = try await chatSendCmd(.apiPrepareContact(userId: userId, connLink: connLink, contactShortLinkData: contactData, verifiedDomain: nil))
        guard case let .newPreparedChat(_, chat) = p, case let .direct(contact) = chat.chatInfo else { throw p.unexpected }
        let c: ChatResponse1 = try await chatSendCmd(.apiConnectPreparedContact(contactId: contact.contactId, incognito: false, msg: nil))
        guard case .startedConnectionToContact = c else { throw c.unexpected }
    } else {
        let c: ChatResponse1 = try await chatSendCmd(.apiConnect(userId: userId, incognito: false, connLink: connLink))
        switch c {
        case .sentConfirmation, .sentInvitation: break
        default: throw c.unexpected
        }
    }
    return .connecting
}

enum ConnectError: LocalizedError {
    case groupsNotSupported

    var errorDescription: String? {
        switch self {
        case .groupsNotSupported: "Joining groups isn't supported in this build yet."
        }
    }
}

// MARK: - Helpers

func validDisplayName(_ name: String) -> Bool {
    mkValidName(name.trimmingCharacters(in: .whitespaces)) == name
}

func mkValidName(_ s: String) -> String {
    var c = s.cString(using: .utf8)!
    return fromCString(chat_valid_name(&c)!)
}
