//
//  AppDelegate.swift
//  SimpleX (macOS)
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Turn SIGTERM (`kill`, logout, shutdown) into a normal quit so the chat shuts down cleanly.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true

        // While waiting for the reply, AppKit runs the main run loop in the modal panel mode,
        // which doesn't service the main dispatch queue or main actor tasks. So the shutdown
        // runs on a background thread and the reply is scheduled in the common run loop modes.
        let lock = NSLock()
        var replied = false
        let reply = {
            lock.lock()
            defer { lock.unlock() }
            guard !replied else { return }
            replied = true
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                sender.reply(toApplicationShouldTerminate: true)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }

        let chatRunning = ChatStore.shared.phase == .running
        DispatchQueue.global(qos: .userInitiated).async {
            ChatStore.shutdown(chatRunning: chatRunning)
            reply()
        }
        // Core calls block and can't be cancelled, so a stuck core must not keep the app from quitting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: reply)
        return .terminateLater
    }
}
