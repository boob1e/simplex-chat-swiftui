# SimpleX for macOS (SwiftUI)

A native macOS client built with SwiftUI on the same Haskell core as the other apps.

- `SimpleXChat` framework: compiled from `apps/ios/SimpleXChat` (models, core FFI, JSON) plus the small macOS shims in `SimpleXChatMac/`.
- `SimpleX` app: the SwiftUI app in `SimpleX/`. It also compiles `apps/ios/Shared/Model/AppAPITypes.swift`, so chat commands and responses match iOS.
- The message history uses `NSTableView` (in `Views/MessageList.swift`) for scrolling performance. Everything else is SwiftUI.

The app is sandboxed and keeps its own database in its container
(`~/Library/Containers/chat.simplex.mac.app/Data/Documents`). It does not touch the Compose desktop app's data.

## Build

Requirements: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), GHC 9.6.3 with cabal (via ghcup), and OpenSSL 3 from Homebrew.

```sh
# 1. Build the Haskell core with Swift JSON encoding and copy it into apps/macos/Libraries
#    (needs cabal.project.local, see docs/CLI.md)
apps/macos/scripts/build-core.sh

# 2. Generate the Xcode project and build
cd apps/macos
xcodegen generate
open SimpleX.xcodeproj   # or: xcodebuild -scheme SimpleX build
```

Don't use a core built by `scripts/desktop/build-lib-mac.sh` alone: without the `swift` flag the core's JSON doesn't decode in Swift, and startup fails with `unknown(json: "{\"type\":\"ok\"}")`.

`SimpleX.xcodeproj` is generated from `project.yml`, so edit `project.yml` rather than the project.

## Status

Implemented (sending and receiving text between accounts verified): profile creation, chat list with search, conversations (text), sending, live updates from the core, one-time invitation links, and connecting via contact links.

Not done yet: files and media, voice messages, joining groups, calls, notifications, multiple profiles, database passphrase and migration, and markdown rendering.
