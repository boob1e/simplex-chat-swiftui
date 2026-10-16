//
//  AvatarView.swift
//  SimpleX (macOS)
//

import SwiftUI

struct AvatarView: View {
    let image: String?
    let name: String
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let nsImage = Self.decode(image) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }

    private static let cache = NSCache<NSString, NSImage>()

    /// Profile images are data URLs: "data:image/jpg;base64,…"
    static func decode(_ dataURL: String?) -> NSImage? {
        guard let dataURL, !dataURL.isEmpty else { return nil }
        let key = dataURL as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
