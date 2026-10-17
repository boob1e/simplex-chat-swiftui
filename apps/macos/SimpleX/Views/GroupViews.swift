//
//  GroupViews.swift
//  SimpleX (macOS)
//
//  Joining groups, creating them, and the group info sheet with members and the group link.
//

import SwiftUI
import SimpleXChat

// MARK: - Joining

extension GroupInfo {
    /// Invited by a contact, or opened from a link, and not joined yet.
    var awaitingJoin: Bool {
        membership.memberStatus == .memInvited || nextConnectPrepared
    }
}

/// Shown instead of the message box until you join.
struct GroupJoinBar: View {
    @Environment(ChatStore.self) private var store
    let groupInfo: GroupInfo
    @State private var working = false
    @State private var error: String?

    private var invited: Bool { groupInfo.membership.memberStatus == .memInvited }

    var body: some View {
        VStack(spacing: 10) {
            Text(invited ? "You're invited to join \(groupInfo.displayName)." : "Join \(groupInfo.displayName) to see and send messages.")
                .font(.callout)
            HStack {
                if invited {
                    Button("Decline", role: .destructive) { run { try await store.deleteChat(ChatData(chatInfo: .group(groupInfo: groupInfo, groupChatScope: nil), chatItems: [])) } }
                }
                Button {
                    run { try await store.joinGroup(groupInfo) }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Join Group") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .disabled(working)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(.bar)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = (error as? LocalizedError)?.errorDescription ?? responseError(error) }
        }
    }
}

// MARK: - Creating

struct NewGroupSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<Int64> = []
    @State private var working = false
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var validName: Bool { !trimmedName.isEmpty && validDisplayName(trimmedName) }

    var body: some View {
        let contacts = store.contactsToInvite(excluding: [])
        VStack(alignment: .leading, spacing: 14) {
            Text("New Group").font(.title2.weight(.semibold))
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
            if !trimmedName.isEmpty && !validName {
                Text("Group names can't contain some characters, such as # or @.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Invite contacts").font(.headline)
            ContactPicker(contacts: contacts, selected: $selected)
                .frame(height: 240)
            Text("You can invite more people later, or share a group link.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create(contacts)
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Create Group") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!validName || working)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create(_ contacts: [Contact]) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let failed = try await store.createGroup(name: trimmedName, inviting: contacts.filter { selected.contains($0.contactId) })
                if failed.isEmpty {
                    dismiss()
                } else {
                    error = String(localized: "The group was created, but these contacts couldn't be invited: \(failed.joined(separator: ", ")).")
                }
            } catch {
                self.error = responseError(error)
            }
        }
    }
}

/// Checklist of contacts.
struct ContactPicker: View {
    let contacts: [Contact]
    @Binding var selected: Set<Int64>

    var body: some View {
        if contacts.isEmpty {
            ContentUnavailableView("No Contacts to Invite", systemImage: "person.2",
                                   description: Text("Connected contacts appear here."))
        } else {
            List(contacts, id: \.contactId) { contact in
                Toggle(isOn: Binding(get: { selected.contains(contact.contactId) },
                                     set: { if $0 { selected.insert(contact.contactId) } else { selected.remove(contact.contactId) } })) {
                    HStack(spacing: 8) {
                        AvatarView(image: contact.image, name: contact.chatViewName, size: 24)
                        Text(contact.chatViewName)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }
}

// MARK: - Group info

struct GroupInfoSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let groupId: Int64

    @State private var members: [GroupMember] = []
    @State private var showInvite = false
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var memberToRemove: GroupMember?
    @State private var error: String?

    /// Kept current from the chat list, which events update.
    private var groupInfo: GroupInfo? {
        if case let .group(g, _) = store.chats.first(where: { $0.id == "#\(groupId)" })?.chatInfo { return g }
        return nil
    }

    var body: some View {
        VStack(spacing: 16) {
            if let groupInfo {
                header(groupInfo)
                membersList(groupInfo)
                if groupInfo.canAddMembers {
                    GroupLinkSection(groupId: groupId)
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                footer(groupInfo)
            } else {
                Text("This group is no longer available.").foregroundStyle(.secondary)
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task(id: store.membersVersion[groupId]) { await loadMembers() }
        .sheet(isPresented: $showInvite) {
            InviteMembersSheet(groupId: groupId, members: members)
        }
        .confirmationDialog("Leave this group?", isPresented: $confirmLeave) {
            Button("Leave Group", role: .destructive) { run { if let g = groupInfo { try await store.leaveGroup(g) } } }
        } message: {
            Text("You'll stop receiving messages from this group. The chat history stays on this Mac.")
        }
        .confirmationDialog("Delete this group?", isPresented: $confirmDelete) {
            Button("Delete Group", role: .destructive) { deleteGroup() }
        } message: {
            Text(groupInfo?.membership.memberCurrent == true && groupInfo?.isOwner == true
                 ? "The group will be deleted for all members. This can't be undone."
                 : "The group will be deleted from this Mac.")
        }
        .confirmationDialog("Remove member?", isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
                            presenting: memberToRemove) { member in
            Button("Remove", role: .destructive) { run { if let g = groupInfo { try await store.removeMember(member, from: g) } } }
        } message: { member in
            Text("\(member.chatViewName) will be removed from the group.")
        }
    }

    private func header(_ g: GroupInfo) -> some View {
        VStack(spacing: 6) {
            AvatarView(image: g.image, name: g.displayName, size: 64)
            Text(g.displayName).font(.title2.weight(.semibold))
            if !g.fullName.isEmpty && g.fullName != g.displayName {
                Text(g.fullName).foregroundStyle(.secondary)
            }
            Text(statusLine(g)).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func statusLine(_ g: GroupInfo) -> String {
        let current = members.filter(\.memberCurrent).count + (g.membership.memberCurrent ? 1 : 0)
        let you = String(localized: "You're \(g.membership.memberRole.text(isChannel: g.isChannel))")
        switch g.membership.memberStatus {
        case .memLeft: return String(localized: "You left this group")
        case .memRemoved: return String(localized: "You were removed from this group")
        case .memGroupDeleted: return String(localized: "This group was deleted")
        case .memInvited: return String(localized: "You're invited")
        default: return "\(current == 1 ? String(localized: "1 member") : String(localized: "\(current) members")) · \(you)"
        }
    }

    private func membersList(_ g: GroupInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Members").font(.headline)
                Spacer()
                if g.canAddMembers {
                    Button("Invite Members…") { showInvite = true }
                        .buttonStyle(.link)
                }
            }
            List {
                MemberRow(member: g.membership, isYou: true, isChannel: g.isChannel)
                ForEach(members.filter { $0.memberStatus != .memLeft && $0.memberStatus != .memRemoved }, id: \.groupMemberId) { m in
                    MemberRow(member: m, isYou: false, isChannel: g.isChannel)
                        .contextMenu { memberMenu(m, g) }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 220)
        }
    }

    @ViewBuilder
    private func memberMenu(_ m: GroupMember, _ g: GroupInfo) -> some View {
        if let contactId = m.memberContactId, store.chats.contains(where: { $0.id == "@\(contactId)" }) {
            Button("Open Chat") {
                store.selectedChatId = "@\(contactId)"
                dismiss()
            }
        }
        if let roles = m.canChangeRoleTo(groupInfo: g) {
            Picker("Role", selection: Binding(get: { m.memberRole }, set: { role in run { try await store.setRole(role, of: m, in: g) } })) {
                ForEach(roles) { Text($0.text(isChannel: g.isChannel).localizedCapitalized).tag($0) }
            }
        }
        if m.canBeRemoved(groupInfo: g) {
            Divider()
            Button("Remove from Group…", role: .destructive) { memberToRemove = m }
        }
    }

    private func footer(_ g: GroupInfo) -> some View {
        HStack {
            if g.membership.memberCurrent {
                Button("Leave Group…", role: .destructive) { confirmLeave = true }
            }
            if g.canDelete {
                Button("Delete Group…", role: .destructive) { confirmDelete = true }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func loadMembers() async {
        do {
            members = try await apiListMembers(groupId)
                .sorted { ($0.memberRole, $1.chatViewName) > ($1.memberRole, $0.chatViewName) }
        } catch {
            self.error = responseError(error)
        }
    }

    private func deleteGroup() {
        guard let chat = store.chats.first(where: { $0.id == "#\(groupId)" }) else { return }
        run {
            try await store.deleteChat(chat)
            dismiss()
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        error = nil
        Task {
            do { try await action() } catch { self.error = responseError(error) }
        }
    }
}

private struct MemberRow: View {
    let member: GroupMember
    let isYou: Bool
    let isChannel: Bool

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(image: member.image, name: member.chatViewName, size: 24)
            Text(isYou ? String(localized: "\(member.chatViewName) (you)") : member.chatViewName)
                .lineLimit(1)
            Spacer()
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if member.memberRole > .member {
                Text(member.memberRole.text(isChannel: isChannel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Only shown while the member isn't fully connected.
    private var status: String? {
        switch member.memberStatus {
        case .memConnected, .memComplete, .memCreator: nil
        case .memInvited: String(localized: "invited")
        case .memPendingApproval, .memPendingReview: String(localized: "pending")
        default: isYou ? nil : String(localized: "connecting")
        }
    }
}

private struct InviteMembersSheet: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let groupId: Int64
    let members: [GroupMember]
    @State private var selected: Set<Int64> = []
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let contacts = store.contactsToInvite(excluding: members)
        VStack(alignment: .leading, spacing: 14) {
            Text("Invite Members").font(.title2.weight(.semibold))
            ContactPicker(contacts: contacts, selected: $selected)
                .frame(height: 260)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    Task {
                        defer { working = false }
                        let failed = await store.invite(contacts.filter { selected.contains($0.contactId) }, to: groupId)
                        if failed.isEmpty { dismiss() } else { error = String(localized: "Couldn't invite: \(failed.joined(separator: ", ")).") }
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Invite") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Link anyone can use to join; admins and owners can create or delete it.
private struct GroupLinkSection: View {
    let groupId: Int64
    @State private var link: GroupLink?
    @State private var loading = true
    @State private var working = false
    @State private var expanded = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Group Link").font(.headline)
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                } else if link == nil {
                    Button("Create Link") { act { link = try await apiCreateGroupLink(groupId); expanded = true } }
                        .buttonStyle(.link)
                        .disabled(working)
                } else {
                    Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                        .buttonStyle(.link)
                    Button("Delete", role: .destructive) { act { try await apiDeleteGroupLink(groupId); link = nil } }
                        .buttonStyle(.link)
                        .foregroundStyle(.red)
                        .disabled(working)
                }
            }
            if let link, expanded {
                LinkShareView(link: simplexChatLink(link.connLinkContact.simplexChatUri(short: true)))
            } else if !loading && link == nil {
                Text("Anyone with a group link can join as a member.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task {
            do { link = try await apiGetGroupLink(groupId) } catch { self.error = responseError(error) }
            loading = false
        }
    }

    private func act(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = responseError(error) }
        }
    }
}
