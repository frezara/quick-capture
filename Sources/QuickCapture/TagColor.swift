import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Deterministic per-tag hue (Finder-tag style dots). Same tag name always
/// picks the same hue across launches (uses DJB2; Swift's built-in String.hash
/// is salted). The editor (editor-web/src/editor.ts) reimplements this hash and
/// palette for section-heading dots — keep the two in sync.
enum TagPalette {
    struct Entry {
        let lightHex: UInt32
        let darkHex: UInt32

        func dot(dark: Bool) -> Color   { Color(hex: dark ? darkHex : lightHex) }
        func label(dark: Bool) -> Color { Color(hex: dark ? darkHex : lightHex) }
        func tint(dark: Bool) -> Color  { Color(hex: dark ? darkHex : lightHex, opacity: dark ? 0.16 : 0.11) }
    }

    private static let entries: [Entry] = [
        .init(lightHex: 0xE8643F, darkHex: 0xF4795A), // coral
        .init(lightHex: 0x2A9D8F, darkHex: 0x3DBDAD), // teal
        .init(lightHex: 0xC2479B, darkHex: 0xDA62B4), // magenta
        .init(lightHex: 0x4F9E4F, darkHex: 0x5FBF60), // green
        .init(lightHex: 0x3B82F6, darkHex: 0x5C9DFF), // blue
        .init(lightHex: 0xC77800, darkHex: 0xE0A33E), // amber
        .init(lightHex: 0x5856D6, darkHex: 0x7D7AFF), // indigo
        .init(lightHex: 0x64748B, darkHex: 0x8B98AB), // slate
    ]

    static func entry(for tag: String) -> Entry {
        let normalized = tag.lowercased()
        var h = 5381
        for u in normalized.unicodeScalars {
            h = ((h << 5) &+ h) &+ Int(u.value)
        }
        return entries[abs(h) % entries.count]
    }
}

/// The app's own AppIcon rendered as a small badge — the panel's identity mark.
/// Sources from `NSApp.applicationIconImage` so it always matches the icon
/// shipped in the asset catalog, no separate copy to keep in sync.
struct AppIconBadge: View {
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
