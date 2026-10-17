//
//  FileViews.swift
//  SimpleX (macOS)
//
//  Images and files inside messages, and attachments waiting to be sent.
//

import SwiftUI
import UniformTypeIdentifiers
import SimpleXChat

/// Transfer state of a message's file, as shown to the user.
enum FileState: Equatable {
    case loaded
    /// Received but not downloaded yet.
    case available
    case transferring(progress: Double?)
    case failed(String)
    case cancelled

    init(_ file: CIFile) {
        switch file.fileStatus {
        case .sndStored, .sndComplete, .rcvComplete: self = file.loaded ? .loaded : .failed(String(localized: "File not found"))
        case let .sndTransfer(done, total): self = .transferring(progress: total > 0 ? Double(done) / Double(total) : nil)
        case let .rcvTransfer(done, total): self = .transferring(progress: total > 0 ? Double(done) / Double(total) : nil)
        case .rcvAccepted: self = .transferring(progress: nil)
        case .rcvInvitation: self = .available
        case .sndCancelled, .rcvCancelled, .rcvAborted: self = .cancelled
        case .sndError, .rcvError: self = .failed(String(localized: "Transfer failed"))
        case .sndWarning, .rcvWarning: self = .transferring(progress: nil) // temporary errors are retried
        case let .invalid(text): self = .failed(text)
        }
    }
}

/// Image or video with its preview, download and progress states. Clicking opens Quick Look.
struct MessageMediaView: View {
    let item: ChatItem
    let file: CIFile
    let preview: String
    var isVideo = false

    private static let maxSide: CGFloat = 300

    var body: some View {
        let state = FileState(file)
        let image = state == .loaded && !isVideo ? loadedImage(file) : nil
        let shown = image ?? AvatarView.decode(preview)
        ZStack {
            if let shown {
                Image(nsImage: shown)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .blur(radius: image == nil && !isVideo ? 6 : 0, opaque: true)
            } else {
                Rectangle().fill(.quaternary)
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
            overlay(state)
        }
        .frame(maxWidth: Self.maxSide, maxHeight: Self.maxSide)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { tap(state) }
        .help(state == .available ? "Download" : "Open in Quick Look")
    }

    @ViewBuilder
    private func overlay(_ state: FileState) -> some View {
        switch state {
        case .loaded:
            if isVideo { circleIcon("play.fill") }
        case .available:
            circleIcon("arrow.down")
        case let .transferring(progress):
            ProgressRing(progress: progress) { ChatStore.shared.cancelFile(file) }
        case .failed:
            circleIcon("exclamationmark")
        case .cancelled:
            circleIcon("xmark")
        }
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(.black.opacity(0.45)))
    }

    private func tap(_ state: FileState) {
        switch state {
        case .loaded: ChatStore.shared.quickLook(item)
        case .available: ChatStore.shared.receiveFile(file)
        default: break
        }
    }
}

/// A file attachment: type icon, name, size or status, and the action that applies.
struct FileRowView: View {
    let item: ChatItem
    let file: CIFile
    var onAccent = false

    var body: some View {
        let state = FileState(file)
        HStack(spacing: 10) {
            Image(nsImage: Self.icon(for: file.fileName))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(state))
                    .font(.caption)
                    .foregroundStyle(onAccent ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 8)
            action(state)
        }
        .frame(minWidth: 200, maxWidth: 320)
        .contentShape(Rectangle())
        .onTapGesture { if state == .loaded { ChatStore.shared.quickLook(item) } }
    }

    private func detail(_ state: FileState) -> String {
        let size = ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)
        switch state {
        case .loaded, .available: return size
        case let .transferring(p?): return "\(Int(p * 100))% of \(size)"
        case .transferring(nil): return String(localized: "Waiting…") + " · " + size
        case let .failed(reason): return reason
        case .cancelled: return String(localized: "Cancelled")
        }
    }

    @ViewBuilder
    private func action(_ state: FileState) -> some View {
        switch state {
        case .available:
            Button { ChatStore.shared.receiveFile(file) } label: { Image(systemName: "arrow.down.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .help("Download")
        case let .transferring(progress):
            ProgressRing(progress: progress, size: 26) { ChatStore.shared.cancelFile(file) }
        case .loaded:
            Button { ChatStore.shared.quickLook(item) } label: { Image(systemName: "eye.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .help("Open in Quick Look (Space)")
        case .failed, .cancelled:
            Image(systemName: "exclamationmark.circle").font(.title2).foregroundStyle(.secondary)
        }
    }

    static func icon(for fileName: String) -> NSImage {
        let ext = (fileName as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

/// Determinate or indeterminate progress, with a stop button in the middle to cancel.
struct ProgressRing: View {
    let progress: Double?
    var size: CGFloat = 44
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(size > 30 ? 0.45 : 0))
            if let progress {
                Circle().stroke(.white.opacity(0.25), lineWidth: 3).padding(5)
                Circle().trim(from: 0, to: max(0.03, progress))
                    .stroke(size > 30 ? Color.white : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(5)
                    .animation(.linear(duration: 0.2), value: progress)
            } else {
                ProgressView().controlSize(size > 30 ? .regular : .small)
            }
            Button(action: cancel) {
                Image(systemName: "stop.fill").font(.system(size: size * 0.22))
            }
            .buttonStyle(.plain)
            .foregroundStyle(size > 30 ? Color.white : Color.accentColor)
            .help("Cancel")
        }
        .frame(width: size, height: size)
    }
}

/// Attachments waiting to be sent, above the message box.
struct AttachmentStrip: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    ZStack(alignment: .topTrailing) {
                        thumbnail(a)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .help(a.name)
                        Button {
                            attachments.removeAll { $0.id == a.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help("Remove")
                    }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 4)
        }
        .frame(height: 76)
    }

    @ViewBuilder
    private func thumbnail(_ a: Attachment) -> some View {
        switch a.kind {
        case let .image(image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        case .file:
            VStack(spacing: 2) {
                Image(nsImage: FileRowView.icon(for: a.name)).resizable().frame(width: 32, height: 32)
                Text(a.name).font(.caption2).lineLimit(1).truncationMode(.middle)
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
        }
    }
}
