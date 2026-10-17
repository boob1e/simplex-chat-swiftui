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
    try await apiSendMessages([ComposedMessage(quotedItemId: quotedItemId, msgContent: .text(text))], to: chat)
}

func apiSendMessages(_ messages: [ComposedMessage], to chat: ChatInfo) async throws -> [ChatItem] {
    let cmd: ChatCommand = .apiSendMessages(
        type: chat.chatType, id: chat.apiId, scope: nil, sendAsGroup: false, live: false, ttl: nil, sign: false,
        composedMessages: messages
    )
    let r: ChatResponse1 = try await chatSendCmd(cmd)
    if case let .newChatItems(_, items) = r { return items.map(\.chatItem) }
    throw r.unexpected
}

func apiUpdateText(_ text: String, of item: ChatItem, in chat: ChatInfo) async throws -> ChatItem {
    let cmd: ChatCommand = .apiUpdateChatItem(
        type: chat.chatType, id: chat.apiId, scope: nil, itemId: item.id,
        updatedMessage: UpdatedMessage(msgContent: .text(text), mentions: [:]), live: false
    )
    let r: ChatResponse1 = try await chatSendCmd(cmd)
    switch r {
    case let .chatItemUpdated(_, a), let .chatItemNotChanged(_, a): return a.chatItem
    default: throw r.unexpected
    }
}

func apiDeleteItems(_ itemIds: [Int64], in chat: ChatInfo, mode: CIDeleteMode) async throws -> [ChatItemDeletion] {
    let r: ChatResponse1 = try await chatSendCmd(.apiDeleteChatItem(type: chat.chatType, id: chat.apiId, scope: nil, itemIds: itemIds, mode: mode))
    if case let .chatItemsDeleted(_, deletions, _) = r { return deletions }
    throw r.unexpected
}

func apiReaction(_ reaction: MsgReaction, add: Bool, to item: ChatItem, in chat: ChatInfo) async throws -> ChatItem {
    let r: ChatResponse1 = try await chatSendCmd(.apiChatItemReaction(type: chat.chatType, id: chat.apiId, scope: nil, itemId: item.id, add: add, reaction: reaction))
    if case let .chatItemReaction(_, _, reaction) = r { return reaction.chatReaction.chatItem }
    throw r.unexpected
}

enum ReceiveFileResult {
    case accepted(AChatItem)
    /// The file is on relays the user hasn't approved; they can see the user's IP address.
    case needsApproval(servers: [String])
}

func apiReceiveFile(_ fileId: Int64, approvedRelays: Bool) async throws -> ReceiveFileResult {
    let r: APIResult<ChatResponse2> = await chatApiSendCmd(.receiveFile(
        fileId: fileId,
        userApprovedRelays: approvedRelays || !privacyAskToApproveRelaysGroupDefault.get(),
        encrypted: privacyEncryptLocalFilesGroupDefault.get(),
        inline: nil
    ))
    switch r {
    case let .result(.rcvFileAccepted(_, item)): return .accepted(item)
    case let .error(.error(.fileNotApproved(_, servers))): return .needsApproval(servers: servers)
    default: throw r.unexpected
    }
}

func apiCancelFile(_ fileId: Int64) async throws -> AChatItem? {
    let r: ChatResponse2 = try await chatSendCmd(.cancelFile(fileId: fileId))
    switch r {
    case let .sndFileCancelled(_, item, _, _), let .rcvFileCancelled(_, item, _): return item
    default: throw r.unexpected
    }
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

func apiSetChatSettings(_ chat: ChatInfo, _ settings: ChatSettings) async throws {
    try await sendCommandOkResp(.apiSetChatSettings(type: chat.chatType, id: chat.apiId, chatSettings: settings))
}

/// Deletes all messages in the chat on this Mac; the contact keeps theirs.
func apiClearChat(_ chat: ChatInfo) async throws -> ChatInfo {
    let r: ChatResponse1 = try await chatSendCmd(.apiClearChat(type: chat.chatType, id: chat.apiId))
    if case let .chatCleared(_, info) = r { return info }
    throw r.unexpected
}

// MARK: - Connecting

func apiAddContact(userId: Int64) async throws -> (CreatedConnLink, PendingContactConnection) {
    let r: ChatResponse1 = try await chatSendCmd(.apiAddContact(userId: userId, incognito: false))
    if case let .invitation(_, link, connection) = r { return (link, connection) }
    throw r.unexpected
}

// MARK: - SimpleX address and contact requests

/// A contact request waiting for the user. Newer cores attach requests to a contact
/// (`Contact.contactRequestId`); older ones use a separate contact request chat.
struct PendingRequest {
    let requestId: Int64
    let chatId: ChatId
    let name: String

    init?(_ info: ChatInfo) {
        switch info {
        case let .contactRequest(r): (requestId, chatId, name) = (r.apiId, r.id, r.chatViewName)
        case let .direct(c):
            // Same condition as iOS: contactRequestId stays set after accepting, but the connection moves on.
            guard c.nextAcceptContactRequest, let id = c.contactRequestId else { return nil }
            (requestId, chatId, name) = (id, c.id, c.chatViewName)
        default: return nil
        }
    }
}

func apiShowMyAddress(userId: Int64) async throws -> UserContactLink? {
    let r: APIResult<ChatResponse1> = await chatApiSendCmd(.apiShowMyAddress(userId: userId))
    switch r {
    case let .result(.userContactLink(_, contactLink)): return contactLink
    case .error(.errorStore(storeError: .userContactLinkNotFound)): return nil
    default: throw r.unexpected
    }
}

func apiCreateMyAddress(userId: Int64) async throws -> CreatedConnLink {
    let r: ChatResponse1 = try await chatSendCmd(.apiCreateMyAddress(userId: userId))
    if case let .userContactLinkCreated(_, link) = r { return link }
    throw r.unexpected
}

func apiDeleteMyAddress(userId: Int64) async throws {
    let r: ChatResponse1 = try await chatSendCmd(.apiDeleteMyAddress(userId: userId))
    if case .userContactLinkDeleted = r { return }
    throw r.unexpected
}

/// Saves the profile and sends it to your contacts. Returns nil when another of your profiles already has this name.
func apiUpdateProfile(userId: Int64, profile: Profile) async throws -> Profile? {
    let r: APIResult<ChatResponse1> = await chatApiSendCmd(.apiUpdateProfile(userId: userId, profile: profile))
    switch r {
    case .result(.userProfileNoChange): return profile
    case let .result(.userProfileUpdated(_, _, toProfile, _)): return toProfile
    case .error(.errorStore(.duplicateName)): return nil
    default: throw r.unexpected
    }
}

func apiAcceptContactRequest(_ contactReqId: Int64) async throws -> Contact {
    let r: ChatResponse1 = try await chatSendCmd(.apiAcceptContact(incognito: false, contactReqId: contactReqId))
    if case let .acceptingContactRequest(_, contact) = r { return contact }
    throw r.unexpected
}

func apiRejectContactRequest(_ contactReqId: Int64) async throws {
    let r: ChatResponse1 = try await chatSendCmd(.apiRejectContact(contactReqId: contactReqId))
    if case .contactRequestRejected = r { return }
    throw r.unexpected
}

enum ConnectResult {
    case connecting
    /// The chat already exists: a known contact, or a group you're in.
    case alreadyConnected(ChatId)
    /// Joining a group: open its chat.
    case joiningGroup(ChatId)
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
    case let .invitationLink(.known(contact)), let .contactAddress(.known(contact)): return .alreadyConnected(contact.id)
    case .invitationLink(.connecting), .contactAddress(.connectingConfirmReconnect), .contactAddress(.connectingProhibit): return .connecting
    case let .groupLink(plan):
        return try await joinViaGroupLink(userId: userId, connLink: connLink, plan: plan)
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

/// Group links: short links carry the group's profile, so the group is prepared as a chat and joined from it;
/// older full links are joined directly and the group appears once the host accepts.
private func joinViaGroupLink(userId: Int64, connLink: CreatedConnLink, plan: GroupLinkPlan) async throws -> ConnectResult {
    switch plan {
    case let .ok(info, data, _):
        if let data {
            let p: ChatResponse1 = try await chatSendCmd(.apiPrepareGroup(userId: userId, connLink: connLink, directLink: info?.direct ?? true, groupShortLinkData: data, verifiedDomain: nil))
            guard case let .newPreparedChat(_, chat) = p, case let .group(groupInfo, _) = chat.chatInfo else { throw p.unexpected }
            _ = try await apiConnectPreparedGroup(groupInfo.groupId)
            return .joiningGroup(groupInfo.id)
        }
        let c: ChatResponse1 = try await chatSendCmd(.apiConnect(userId: userId, incognito: false, connLink: connLink))
        switch c {
        case .sentConfirmation, .sentInvitation: return .connecting
        default: throw c.unexpected
        }
    case .ownLink: return .ownLink
    case let .known(groupInfo): return .alreadyConnected(groupInfo.id)
    case let .connectingProhibit(groupInfo?): return .alreadyConnected(groupInfo.id)
    case .connectingConfirmReconnect, .connectingProhibit(nil): return .connecting
    case .noRelays, .updateRequired: throw ConnectError.channelUnavailable
    }
}

enum ConnectError: LocalizedError {
    case channelUnavailable
    case invitationRemoved

    var errorDescription: String? {
        switch self {
        case .channelUnavailable: "This channel can't be joined right now. Try again later, or update the app."
        case .invitationRemoved: "This invitation is no longer valid. The group may have been deleted, or the invitation withdrawn."
        }
    }
}

// MARK: - Groups

func apiNewGroup(userId: Int64, name: String) async throws -> GroupInfo {
    let r: ChatResponse2 = try await chatSendCmd(.apiNewGroup(userId: userId, incognito: false, groupProfile: GroupProfile(displayName: name, fullName: "")))
    if case let .groupCreated(_, groupInfo) = r { return groupInfo }
    throw r.unexpected
}

func apiAddMember(groupId: Int64, contactId: Int64, role: GroupMemberRole) async throws -> GroupMember {
    let r: ChatResponse2 = try await chatSendCmd(.apiAddMember(groupId: groupId, contactId: contactId, memberRole: role))
    if case let .sentGroupInvitation(_, _, _, member) = r { return member }
    throw r.unexpected
}

/// Accepts an invitation received from a contact.
func apiJoinGroup(_ groupId: Int64) async throws -> GroupInfo {
    let r: APIResult<ChatResponse2> = await chatApiSendCmd(.apiJoinGroup(groupId: groupId))
    switch r {
    case let .result(.userAcceptedGroupSent(_, groupInfo, _)): return groupInfo
    case .error(.errorAgent(.SMP(_, .AUTH))), .error(.errorStore(.groupNotFound)): throw ConnectError.invitationRemoved
    default: throw r.unexpected
    }
}

/// Joins a group opened from a link.
func apiConnectPreparedGroup(_ groupId: Int64) async throws -> GroupInfo {
    let r: ChatResponse1 = try await chatSendCmd(.apiConnectPreparedGroup(groupId: groupId, incognito: false, msg: nil))
    if case let .startedConnectionToGroup(_, groupInfo, _) = r { return groupInfo }
    throw r.unexpected
}

func apiLeaveGroup(_ groupId: Int64) async throws -> GroupInfo {
    let r: ChatResponse2 = try await chatSendCmd(.apiLeaveGroup(groupId: groupId))
    if case let .leftMemberUser(_, groupInfo) = r { return groupInfo }
    throw r.unexpected
}

func apiListMembers(_ groupId: Int64) async throws -> [GroupMember] {
    let r: ChatResponse2 = try await chatSendCmd(.apiListMembers(groupId: groupId))
    if case let .groupMembers(_, group) = r { return group.members }
    throw r.unexpected
}

func apiRemoveMember(_ groupId: Int64, _ memberId: Int64) async throws -> GroupInfo {
    let r: ChatResponse2 = try await chatSendCmd(.apiRemoveMembers(groupId: groupId, memberIds: [memberId], withMessages: false))
    if case let .userDeletedMembers(_, groupInfo, _, _) = r { return groupInfo }
    throw r.unexpected
}

func apiSetMemberRole(_ groupId: Int64, _ memberId: Int64, _ role: GroupMemberRole) async throws {
    let r: ChatResponse2 = try await chatSendCmd(.apiMembersRole(groupId: groupId, memberIds: [memberId], memberRole: role))
    if case .membersRoleUser = r { return }
    throw r.unexpected
}

func apiGetGroupLink(_ groupId: Int64) async throws -> GroupLink? {
    let r: APIResult<ChatResponse2> = await chatApiSendCmd(.apiGetGroupLink(groupId: groupId))
    switch r {
    case let .result(.groupLink(_, _, link)): return link
    case .error(.errorStore(.groupLinkNotFound)): return nil
    default: throw r.unexpected
    }
}

func apiCreateGroupLink(_ groupId: Int64) async throws -> GroupLink {
    let r: ChatResponse2 = try await chatSendCmd(.apiCreateGroupLink(groupId: groupId, memberRole: .member))
    if case let .groupLinkCreated(_, _, link) = r { return link }
    throw r.unexpected
}

func apiDeleteGroupLink(_ groupId: Int64) async throws {
    let r: ChatResponse2 = try await chatSendCmd(.apiDeleteGroupLink(groupId: groupId))
    if case .groupLinkDeleted = r { return }
    throw r.unexpected
}

// MARK: - Helpers

func validDisplayName(_ name: String) -> Bool {
    mkValidName(name.trimmingCharacters(in: .whitespaces)) == name
}

func mkValidName(_ s: String) -> String {
    var c = s.cString(using: .utf8)!
    return fromCString(chat_valid_name(&c)!)
}

/// Moves the database key from the login keychain (used by earlier builds) to the data protection keychain.
/// The legacy item is removed only after the new one is saved, so the key can't be lost.
func migrateDatabaseKeyFromLegacyKeychain() {
    guard kcDatabasePassword.get() == nil else { return }
    let legacy: [NSString: AnyObject] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrAccount: "databasePassword" as NSString,
        kSecUseDataProtectionKeychain: kCFBooleanFalse,
    ]
    var query = legacy
    query[kSecReturnData] = kCFBooleanTrue
    query[kSecMatchLimit] = kSecMatchLimitOne
    var ref: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
          let data = ref as? Data, let key = String(data: data, encoding: .utf8) else { return }
    if kcDatabasePassword.set(key), kcDatabasePassword.get() == key {
        let status = SecItemDelete(legacy as CFDictionary)
        logger.notice("database key moved to the data protection keychain (legacy delete status \(status))")
    } else {
        logger.error("couldn't move the database key to the data protection keychain; still using the login keychain item")
    }
}
