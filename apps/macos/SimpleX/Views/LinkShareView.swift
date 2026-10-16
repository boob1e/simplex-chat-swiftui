//
//  LinkShareView.swift
//  SimpleX (macOS)
//
//  QR code and link for a SimpleX address or invitation, with copy and share.
//

import SwiftUI
import CoreImage.CIFilterBuiltins
import SimpleXChat

struct LinkShareView: View {
    /// Link as shown and shared, e.g. https://simplex.chat/…
    let link: String

    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            QRCodeView(text: link)
                .frame(width: 220, height: 220)

            Text(link)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: link) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }
}

/// Black-on-white QR code drawn with nearest-neighbour scaling, so it stays sharp at any size.
struct QRCodeView: View {
    let text: String

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                    .contextMenu {
                        Button("Copy Image") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([Self.image(for: text, scale: 12) ?? image])
                        }
                    }
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func image(for text: String, scale: CGFloat = 1) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
