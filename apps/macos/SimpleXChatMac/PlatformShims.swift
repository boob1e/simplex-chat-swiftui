//
//  PlatformShims.swift
//  SimpleXChat (macOS)
//
//  Lets the shared iOS sources compile against AppKit.
//

import AppKit

public typealias UIImage = NSImage
public typealias UIColor = NSColor
public typealias UIFont = NSFont
public typealias UIFontDescriptor = NSFontDescriptor

import SwiftUI

extension Image {
    public init(uiImage: NSImage) {
        self.init(nsImage: uiImage)
    }
}
