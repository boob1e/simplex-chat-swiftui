//
//  DesktopImport.swift
//  SimpleX (macOS)
//
//  Moves the profile, contacts and messages of the official SimpleX desktop app into this app.
//  The desktop app keeps its data in ~/.local/share/simplex (simplex_v1_* databases and files)
//  and its database key in ~/.config/simplex/settings.properties; the sandbox allows reading
//  those two folders (see SimpleX.entitlements).
//
//  The import runs at launch, before the core opens a database: choosing it quits the app and
//  starts it again. The desktop data is copied, not moved, and is left as it was.
//

import AppKit
import SimpleXChat

enum DesktopImport {
    static let desktopBundleId = "chat.simplex.app"
    private static let pendingKey = "desktopImportPending"

    private static var realHome: URL {
        // In the sandbox, the home directory APIs return the app's container.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var dataDir: URL { realHome.appendingPathComponent(".local/share/simplex", isDirectory: true) }
    private static var settingsFile: URL { realHome.appendingPathComponent(".config/simplex/settings.properties") }
    private static func desktopDB(_ suffix: String) -> URL { dataDir.appendingPathComponent("simplex_v1_\(suffix).db") }

    static var desktopDataExists: Bool {
        FileManager.default.fileExists(atPath: desktopDB("chat").path) && FileManager.default.fileExists(atPath: desktopDB("agent").path)
    }

    static var desktopAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleId).isEmpty
    }

    /// Set when the import was chosen; the app relaunches on quit and imports before opening the database.
    static var pending: Bool {
        get { UserDefaults.standard.bool(forKey: pendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: pendingKey) }
    }

    enum ImportError: LocalizedError {
        case noDesktopData
        case desktopAppRunning
        case noKey
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDesktopData: "No SimpleX desktop app data was found in ~/.local/share/simplex."
            case .desktopAppRunning: "Quit the SimpleX desktop app before importing its data, then try again."
            case .noKey: "The desktop app's database key wasn't found. If you set your own database passphrase in the desktop app, this import can't use it yet."
            case let .copyFailed(reason): "The data couldn't be copied: \(reason). Nothing was changed."
            }
        }
    }

    /// The key the desktop app stores in its settings: base64 of the passphrase (desktop doesn't encrypt it).
    static func readDesktopKey() throws -> String {
        guard let text = try? String(contentsOf: settingsFile, encoding: .utf8) else { throw ImportError.noKey }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("EncryptedDBPassphrase=") {
            // Java properties escape some characters (=, :) with a backslash.
            let value = line.dropFirst("EncryptedDBPassphrase=".count).replacingOccurrences(of: "\\", with: "")
            if let data = Data(base64Encoded: value), let key = String(data: data, encoding: .utf8), !key.isEmpty {
                return key
            }
        }
        throw ImportError.noKey
    }

    /// Checks everything that can be checked before quitting.
    static func checkReady() throws {
        guard desktopDataExists else { throw ImportError.noDesktopData }
        guard !desktopAppRunning else { throw ImportError.desktopAppRunning }
        _ = try readDesktopKey()
    }

    /// Replaces this app's databases and files with copies of the desktop app's.
    /// Copies go to a staging folder first, so a failure leaves the current data in place.
    /// The replaced data is deleted once the new data and key are in place.
    static func perform() throws {
        pending = false
        try checkReady()
        let key = try readDesktopKey()
        let fm = FileManager.default
        let docs = getDocumentsDirectory()
        let staging = docs.appendingPathComponent("desktop-import", isDirectory: true)
        let replaced = docs.appendingPathComponent("replaced-by-import", isDirectory: true)
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: replaced)

        let dbNames = ["chat", "agent"]
        let dbPrefix = getAppDatabasePath().lastPathComponent
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for name in dbNames {
                try fm.copyItem(at: desktopDB(name), to: staging.appendingPathComponent("\(dbPrefix)_\(name).db"))
            }
            let desktopFiles = dataDir.appendingPathComponent("simplex_v1_files", isDirectory: true)
            let stagedFiles = staging.appendingPathComponent(getAppFilesDirectory().lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: desktopFiles.path) {
                try fm.copyItem(at: desktopFiles, to: stagedFiles)
            } else {
                try fm.createDirectory(at: stagedFiles, withIntermediateDirectories: true)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw ImportError.copyFailed(error.localizedDescription)
        }

        // Move the current data aside, then the staged data in.
        let current = dbNames.flatMap { n in ["", "-wal", "-shm"].map { "\(dbPrefix)_\(n).db\($0)" } } + [getAppFilesDirectory().lastPathComponent]
        let oldKey = kcDatabasePassword.get()
        do {
            try fm.createDirectory(at: replaced, withIntermediateDirectories: true)
            for name in current where fm.fileExists(atPath: docs.appendingPathComponent(name).path) {
                try fm.moveItem(at: docs.appendingPathComponent(name), to: replaced.appendingPathComponent(name))
            }
            for name in try fm.contentsOfDirectory(atPath: staging.path) {
                try fm.moveItem(at: staging.appendingPathComponent(name), to: docs.appendingPathComponent(name))
            }
            guard kcDatabasePassword.set(key), kcDatabasePassword.get() == key else { throw ImportError.copyFailed("the key couldn't be saved to the keychain") }
            storeDBPassphraseGroupDefault.set(true)
        } catch {
            // Put the previous data and key back.
            for name in current where fm.fileExists(atPath: replaced.appendingPathComponent(name).path) {
                try? fm.removeItem(at: docs.appendingPathComponent(name))
                try? fm.moveItem(at: replaced.appendingPathComponent(name), to: docs.appendingPathComponent(name))
            }
            if let oldKey { _ = kcDatabasePassword.set(oldKey) }
            try? fm.removeItem(at: staging)
            throw (error as? ImportError) ?? ImportError.copyFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: replaced)
        logger.notice("imported desktop app data")
    }

    /// Quits, and opens the app again once this instance has closed its database.
    static func scheduleAndRelaunch() {
        pending = true
        relaunchOnQuit = true
        NSApp.terminate(nil)
    }

    /// AppDelegate opens a new instance when this one terminates.
    static var relaunchOnQuit = false
}

import SwiftUI

/// Confirmation for the import, and the reason when an import didn't happen.
struct DesktopImportConfirmation: ViewModifier {
    @Environment(ChatStore.self) private var store
    @State private var problem: String?

    func body(content: Content) -> some View {
        content
            .alert("Import data from the SimpleX desktop app?", isPresented: Binding(get: { store.showDesktopImport }, set: { store.showDesktopImport = $0 })) {
                Button("Import and Restart", role: .destructive) { start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("""
                Your profiles, contacts, groups, messages and files from the desktop app are copied into this app, \
                and this app's current data\(store.currentUser.map { " (profile \($0.displayName))" } ?? "") is deleted. \
                SimpleX restarts to do this.

                Afterwards, don't use the desktop app with the same data. Both apps would share the same connections, \
                and messages would go missing or connections would break. The desktop app's files are left as they were.
                """)
            }
            .alert("Can't import", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
            .alert("Import didn't happen", isPresented: Binding(get: { store.importError != nil }, set: { if !$0 { store.importError = nil } })) {
                Button("OK") {}
            } message: {
                Text("\(store.importError ?? "") Your existing data in this app was kept.")
            }
    }

    private func start() {
        do {
            try DesktopImport.checkReady()
            DesktopImport.scheduleAndRelaunch()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
