//
//  FileSupport.swift
//  SimpleX (macOS)
//
//  Images and files for messages: preparing attachments to send, and reading received files.
//  Mirrors the iOS rules (apps/ios/SimpleXChat/ImageUtils.swift) so other clients show them the same way:
//  image messages carry a small base64 preview and a full image of at most MAX_IMAGE_SIZE.
//

import AppKit
import UniformTypeIdentifiers
import SimpleXChat

/// Base64 preview size inside image messages, as on iOS.
private let previewMaxSize: Int64 = 14_000

// MARK: - Reading received or sent files

/// Data of a file that finished transferring, decrypting it if it's stored encrypted.
func loadedFileData(_ file: CIFile?) -> Data? {
    guard let source = loadedFileSource(file) else { return nil }
    let path = getAppFilePath(source.filePath)
    if let args = source.cryptoArgs {
        return try? readCryptoFile(path: path.path, cryptoArgs: args)
    }
    return try? Data(contentsOf: path)
}

func loadedFileSource(_ file: CIFile?) -> CryptoFile? {
    guard let file, file.loaded, let source = file.fileSource,
          FileManager.default.fileExists(atPath: getAppFilePath(source.filePath).path) else { return nil }
    return source
}

private let imageCache = NSCache<NSString, NSImage>()

func loadedImage(_ file: CIFile?) -> NSImage? {
    guard let source = loadedFileSource(file) else { return nil }
    let key = source.filePath as NSString
    if let cached = imageCache.object(forKey: key) { return cached }
    guard let data = loadedFileData(file), let image = NSImage(data: data) else { return nil }
    imageCache.setObject(image, forKey: key)
    return image
}

/// A readable copy of the file for Quick Look, opening, or saving: the file itself when it's
/// not encrypted, otherwise a decrypted copy in the temporary folder under its original name.
func readableFileURL(_ file: CIFile?) -> URL? {
    guard let file, let source = loadedFileSource(file) else { return nil }
    let path = getAppFilePath(source.filePath)
    guard let args = source.cryptoArgs else { return path }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("decrypted-\(file.fileId)", isDirectory: true)
    let url = dir.appendingPathComponent(file.fileName)
    if FileManager.default.fileExists(atPath: url.path) { return url }
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try decryptCryptoFile(fromPath: path.path, cryptoArgs: args, toPath: url.path)
        return url
    } catch {
        logger.error("decrypting file \(file.fileId): \(error.localizedDescription)")
        return nil
    }
}

/// Removes decrypted copies made for Quick Look and saving, and copies of dropped files.
func removeDecryptedCopies() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
    for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("decrypted-") || name.hasPrefix("outgoing-") {
        try? fm.removeItem(at: tmp.appendingPathComponent(name))
    }
}

// MARK: - Preparing attachments

/// Something chosen to send: an image (sent as an image message) or any other file.
struct Attachment: Identifiable {
    let id = UUID()
    let kind: Kind
    let name: String
    let size: Int64

    enum Kind {
        case image(NSImage)
        case file(URL)
    }

    /// Files dropped or chosen from disk; images become image messages unless they're animated or huge.
    static func from(url: URL) -> Attachment? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { return nil }
        let size = Int64(values?.fileSize ?? 0)
        let type = values?.contentType
        if let type, type.conforms(to: .image), !type.conforms(to: .gif), size < 50_000_000, let image = NSImage(contentsOf: url) {
            return Attachment(kind: .image(image), name: url.lastPathComponent, size: size)
        }
        return Attachment(kind: .file(url), name: url.lastPathComponent, size: size)
    }

    /// Dragged or pasted files: the sandbox may only allow reading them briefly,
    /// so they're copied into the temporary folder straight away.
    static func fromTransferred(url: URL) -> Attachment? {
        guard url.isFileURL else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing-\(UUID().uuidString)", isDirectory: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            logger.error("copying dropped file: \(error.localizedDescription)")
            return nil
        }
        return from(url: copy)
    }

    static func from(image: NSImage) -> Attachment {
        Attachment(kind: .image(image), name: "Image", size: 0)
    }
}

enum AttachmentError: LocalizedError {
    case tooLarge(String, Int64)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case let .tooLarge(name, max):
            "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: max, countStyle: .file)), the most SimpleX can send."
        case let .unreadable(name):
            "\(name) couldn't be read."
        }
    }
}

/// Stores the attachment in the app's files folder (encrypted, like iOS by default)
/// and returns the message content and file to send.
func prepareForSending(_ attachment: Attachment, caption: String) throws -> (MsgContent, CryptoFile) {
    let encrypt = privacyEncryptLocalFilesGroupDefault.get()
    switch attachment.kind {
    case let .image(image):
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AttachmentError.unreadable(attachment.name) }
        let hasAlpha = cgImageHasAlpha(cg)
        guard let full = resizedImageData(cg, maxDataSize: MAX_IMAGE_SIZE, png: hasAlpha),
              let preview = resizedImageData(cg, maxDataSize: previewMaxSize * 3 / 4, png: false) else {
            throw AttachmentError.unreadable(attachment.name)
        }
        let fileName = uniqueFileName("IMG_\(timestamp())", hasAlpha ? "png" : "jpg")
        guard let file = saveFile(full, fileName, encrypted: encrypt) else { throw AttachmentError.unreadable(attachment.name) }
        let previewStr = "data:image/jpg;base64,\(preview.base64EncodedString())"
        return (.image(text: caption, image: previewStr), file)

    case let .file(url):
        let max = getMaxFileSize(.xftp)
        guard attachment.size <= max else { throw AttachmentError.tooLarge(attachment.name, max) }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let fileName = uniqueFileName(base.isEmpty ? "file" : base, ext)
        let dest = getAppFilePath(fileName)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            if encrypt {
                let args = try encryptCryptoFile(fromPath: url.path, toPath: dest.path)
                return (.file(caption), CryptoFile(filePath: fileName, cryptoArgs: args))
            } else {
                try FileManager.default.copyItem(at: url, to: dest)
                return (.file(caption), CryptoFile.plain(fileName))
            }
        } catch {
            throw AttachmentError.unreadable(attachment.name)
        }
    }
}

/// Re-encodes the image, shrinking it until the encoded data fits in maxDataSize.
private func resizedImageData(_ image: CGImage, maxDataSize: Int64, png: Bool) -> Data? {
    var img = image
    var data = encode(img, png: png)
    while let d = data, Int64(d.count) > maxDataSize {
        let ratio = min(2.0, sqrt(Double(d.count) / Double(maxDataSize)))
        let width = Int(Double(img.width) / ratio), height = Int(Double(img.height) / ratio)
        guard width > 8, height > 8, let smaller = scaled(img, width: width, height: height) else { return nil }
        img = smaller
        data = encode(img, png: png)
    }
    return data
}

private func encode(_ image: CGImage, png: Bool) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    return png ? rep.representation(using: .png, properties: [:])
               : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
}

private func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

/// Whether any pixel is actually transparent (screenshots often have an alpha channel but no transparency).
/// Checked on a small copy, like iOS checks pixels, so opaque images go as JPEG.
private func cgImageHasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: break
    }
    let scale = min(1, 256 / Double(max(image.width, image.height)))
    let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let pixels = { ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }() else { return true }
    let bytes = pixels.assumingMemoryBound(to: UInt8.self)
    for i in stride(from: 3, to: w * h * 4, by: 4) where bytes[i] < 255 { return true }
    return false
}

private func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: .now)
}

private func uniqueFileName(_ base: String, _ ext: String) -> String {
    var n = 0
    while true {
        let name = (n == 0 ? base : "\(base)_\(n)") + (ext.isEmpty ? "" : ".\(ext)")
        if !FileManager.default.fileExists(atPath: getAppFilePath(name).path) { return name }
        n += 1
    }
}
