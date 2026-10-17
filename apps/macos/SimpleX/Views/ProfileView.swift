//
//  ProfileView.swift
//  SimpleX (macOS)
//
//  Your profile, SimpleX address and one-time invitation links.
//

import SwiftUI
import SimpleXChat

struct ProfileView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case address = "SimpleX Address"
        case oneTime = "One-Time Link"
        var id: Self { self }
    }

    @State private var tab: Tab = .address
    @State private var editing = false

    var body: some View {
        VStack(spacing: 18) {
            if let user = store.currentUser {
                if editing {
                    EditProfileForm(user: user) { editing = false }
                } else {
                    VStack(spacing: 6) {
                        AvatarView(image: user.image, name: user.displayName, size: 64)
                        Text(user.displayName).font(.title2.weight(.semibold))
                        if !user.fullName.isEmpty {
                            Text(user.fullName).foregroundStyle(.secondary)
                        }
                        Button("Edit Profile") { editing = true }
                            .buttonStyle(.link)
                    }
                }
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Group {
                switch tab {
                case .address: AddressTab()
                case .oneTime: OneTimeLinkTab()
                }
            }
            .frame(minHeight: 340)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Name and picture, sent to all your contacts when saved.
private struct EditProfileForm: View {
    @Environment(ChatStore.self) private var store
    let done: () -> Void

    @State private var displayName: String
    @State private var fullName: String
    @State private var image: String?
    @State private var saving = false
    @State private var error: String?
    private let original: Profile

    init(user: User, done: @escaping () -> Void) {
        let profile = fromLocalProfile(user.profile)
        original = profile
        self.done = done
        _displayName = State(initialValue: profile.displayName)
        _fullName = State(initialValue: profile.fullName)
        _image = State(initialValue: profile.image)
    }

    var body: some View {
        VStack(spacing: 12) {
            Menu {
                Button("Choose Picture…", action: choosePicture)
                if image != nil {
                    Button("Remove Picture", role: .destructive) { image = nil }
                }
            } label: {
                AvatarView(image: image, name: displayName.isEmpty ? original.displayName : displayName, size: 64)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.title3)
                    }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change picture")

            Form {
                TextField("Display name", text: $displayName)
                TextField("Full name", text: $fullName, prompt: Text("Optional"))
            }
            .formStyle(.grouped)
            .frame(maxWidth: 360, maxHeight: 120)
            .onSubmit(save)

            if let nameProblem {
                Text(nameProblem).font(.callout).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Button("Cancel", action: done)
                Button(action: save) {
                    if saving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
    }

    private var trimmedName: String { displayName.trimmingCharacters(in: .whitespaces) }

    private var nameProblem: String? {
        if trimmedName.isEmpty { return String(localized: "Enter a display name.") }
        if !validDisplayName(trimmedName) { return String(localized: "Display names can't contain some characters, such as # or @, and can't start with a space.") }
        return nil
    }

    private var edited: Profile {
        var p = original
        p.displayName = trimmedName
        p.fullName = fullName.trimmingCharacters(in: .whitespaces)
        p.image = image
        return p
    }

    private var canSave: Bool { !saving && nameProblem == nil && edited != original }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let picked = NSImage(contentsOf: url), let str = avatarImageString(picked) else {
            error = String(localized: "That picture couldn't be read.")
            return
        }
        error = nil
        image = str
    }

    private func save() {
        guard canSave else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                if try await store.updateProfile(edited) {
                    done()
                } else {
                    error = String(localized: "You already have a profile named \(trimmedName).")
                }
            } catch {
                self.error = responseError(error)
            }
        }
    }
}

/// Long-term address: anyone with it can send you a contact request.
private struct AddressTab: View {
    @Environment(ChatStore.self) private var store
    @State private var address: UserContactLink?
    @State private var loading = true
    @State private var working = false
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            if loading {
                ProgressView()
            } else if let address {
                Text("People can use this address to send you contact requests. You choose whether to accept each one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                LinkShareView(link: simplexChatLink(address.connLinkContact.simplexChatUri(short: true)))
                Button("Delete Address…", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
                    .disabled(working)
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("Create an address to share publicly, for example on social media or a website. People who use it send you a contact request, and you decide whether to accept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button {
                    create()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Create SimpleX Address") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task { await load() }
        .confirmationDialog("Delete your SimpleX address?", isPresented: $confirmDelete) {
            Button("Delete Address", role: .destructive) { delete() }
        } message: {
            Text("Nobody will be able to send you contact requests with it anymore. Contacts you already have are not affected.")
        }
    }

    private func load() async {
        guard let userId = store.currentUser?.userId else { return }
        do {
            address = try await apiShowMyAddress(userId: userId)
        } catch {
            self.error = responseError(error)
        }
        loading = false
    }

    private func create() {
        guard let userId = store.currentUser?.userId else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                _ = try await apiCreateMyAddress(userId: userId)
                address = try await apiShowMyAddress(userId: userId)
            } catch {
                self.error = responseError(error)
            }
        }
    }

    private func delete() {
        guard let userId = store.currentUser?.userId else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await apiDeleteMyAddress(userId: userId)
                address = nil
            } catch {
                self.error = responseError(error)
            }
        }
    }
}

/// Single-use invitation: the first person to use it becomes your contact.
struct OneTimeLinkTab: View {
    @Environment(ChatStore.self) private var store
    @State private var link: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Text("A one-time link works for a single person. Share it privately, in person or over a channel you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let link {
                LinkShareView(link: link)
                Button("Create Another Link") { create() }
                    .buttonStyle(.link)
                    .disabled(working)
            } else {
                Button {
                    create()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Create One-Time Link") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func create() {
        guard let userId = store.currentUser?.userId else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let (created, _) = try await apiAddContact(userId: userId)
                link = simplexChatLink(created.simplexChatUri(short: true))
                try? await store.reloadChats()
            } catch {
                self.error = responseError(error)
            }
        }
    }
}
