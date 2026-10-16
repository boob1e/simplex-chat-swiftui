//
//  FormattedText.swift
//  SimpleX (macOS)
//
//  Turns the core's parsed markdown ([FormattedText]) into an AttributedString.
//

import SwiftUI
import SimpleXChat

/// Links inside messages use these schemes for in-app actions; everything else opens in the system.
enum MessageLink {
    static let secretScheme = "simplex-secret"
    static let connectScheme = "simplex-connect"

    static func secret(_ index: Int) -> URL { URL(string: "\(secretScheme)://\(index)")! }

    /// SimpleX links open the in-app connect flow instead of a browser.
    static func connect(_ simplexUri: String) -> URL? {
        var c = URLComponents()
        c.scheme = connectScheme
        c.host = "link"
        c.queryItems = [URLQueryItem(name: "uri", value: simplexUri)]
        return c.url
    }

    static func connectUri(_ url: URL) -> String? {
        guard url.scheme == connectScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "uri" }?.value
    }
}

struct MessageTextStyle {
    /// Text sits on the accent-colored bubble.
    var onAccent: Bool
    /// Indexes of secret runs the user has revealed.
    var revealedSecrets: Set<Int> = []
    var mentions: [String: CIMention]? = nil
    var userMemberId: String? = nil
}

func formattedMessage(_ text: String, _ formatted: [FormattedText]?, style: MessageTextStyle) -> AttributedString {
    guard let formatted, !formatted.isEmpty else { return AttributedString(text) }
    var res = AttributedString()
    var secretIndex = 0
    for ft in formatted {
        var s = AttributedString(ft.text)
        switch ft.format {
        case nil, .unknown:
            break
        case .bold:
            s.inlinePresentationIntent = .stronglyEmphasized
        case .italic:
            s.inlinePresentationIntent = .emphasized
        case .strikeThrough:
            s.strikethroughStyle = .single
        case .snippet:
            s.font = .body.monospaced()
        case .secret:
            if !style.revealedSecrets.contains(secretIndex) {
                s.foregroundColor = .clear
                s.backgroundColor = style.onAccent ? Color.white.opacity(0.45) : Color.secondary.opacity(0.45)
            }
            s.link = MessageLink.secret(secretIndex)
            secretIndex += 1
        case .small:
            s.font = .footnote
            s.foregroundColor = style.onAccent ? Color.white.opacity(0.75) : Color.secondary
        case let .colored(color):
            if let c = color.uiColor { s.foregroundColor = c }
        case .uri:
            let href = ft.text.hasPrefix("http://") || ft.text.hasPrefix("https://") ? ft.text : "https://" + ft.text
            link(&s, URL(string: href), style)
        case let .hyperLink(showText, uri):
            if let showText { s = AttributedString(showText) }
            link(&s, URL(string: uri), style)
        case let .simplexLink(showText, linkType, simplexUri, smpHosts):
            s = AttributedString(showText ?? linkType.description)
            let url = MessageLink.connect(simplexUri)
            link(&s, url, style)
            if showText == nil, !smpHosts.isEmpty {
                var via = AttributedString(" " + viaHost(smpHosts))
                via.inlinePresentationIntent = .emphasized
                link(&via, url, style)
                s += via
            }
        case .simplexName:
            link(&s, nil, style)
        case let .command(cmd):
            s = AttributedString("/" + cmd)
            s.font = .body.monospaced()
        case let .mention(memberName):
            let mention = style.mentions?[memberName]
            let ref = mention?.memberRef
            let name = if let ref, let alias = ref.localAlias, !alias.isEmpty { "\(alias) (\(ref.displayName))" } else { ref?.displayName ?? memberName }
            s = AttributedString("@" + (name.contains(" ") ? "'\(name)'" : name))
            s.inlinePresentationIntent = .stronglyEmphasized
            if let mention, mention.memberId == style.userMemberId, !style.onAccent {
                s.foregroundColor = .accentColor
            }
        case let .modal(_, text):
            s = AttributedString(text)
            link(&s, nil, style)
        case .email:
            link(&s, URL(string: "mailto:" + ft.text), style)
        case .phone:
            link(&s, URL(string: "tel:" + ft.text.replacingOccurrences(of: " ", with: "")), style)
        }
        res += s
    }
    return res
}

/// Plain text for chat list previews and notifications: link labels instead of markdown syntax.
func plainMessageText(_ text: String, _ formatted: [FormattedText]?) -> String {
    guard let formatted, !formatted.isEmpty else { return text }
    return formatted.map { ft in
        switch ft.format {
        case let .hyperLink(showText?, _): showText
        case let .simplexLink(showText, linkType, _, _): showText ?? linkType.description
        case let .command(cmd): "/" + cmd
        case let .mention(name): "@" + name
        case let .modal(_, text): text
        default: ft.text
        }
    }.joined()
}

private func link(_ s: inout AttributedString, _ url: URL?, _ style: MessageTextStyle) {
    if let url { s.link = url }
    // On the accent bubble the default link color would disappear, so links are white and underlined.
    if style.onAccent {
        s.foregroundColor = .white
        s.underlineStyle = .single
    }
}

private func viaHost(_ smpHosts: [String]) -> String {
    let first = smpHosts.first ?? "?"
    return smpHosts.count > 1
        ? String(localized: "(via \(first) and \(smpHosts.count - 1) more)")
        : String(localized: "(via \(first))")
}
