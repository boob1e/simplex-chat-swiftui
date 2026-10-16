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

    var body: some View {
        VStack(spacing: 18) {
            if let user = store.currentUser {
                VStack(spacing: 6) {
                    AvatarView(image: user.image, name: user.displayName, size: 64)
                    Text(user.displayName).font(.title2.weight(.semibold))
                    if !user.fullName.isEmpty {
                        Text(user.fullName).foregroundStyle(.secondary)
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
