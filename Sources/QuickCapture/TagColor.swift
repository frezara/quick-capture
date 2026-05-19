import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Deterministic per-tag color palette. Same tag name always picks the same
/// hue across launches (uses DJB2; Swift's built-in String.hash is salted).
enum TagPalette {
    struct Entry {
        let primaryHex: UInt32
        let foregroundHex: UInt32

        var bg: Color     { Color(hex: primaryHex, opacity: 0.10) }
        var fg: Color     { Color(hex: foregroundHex) }
        var border: Color { Color(hex: primaryHex, opacity: 0.20) }
    }

    private static let entries: [Entry] = [
        .init(primaryHex: 0x5E6AD2, foregroundHex: 0x4A52B0), // indigo
        .init(primaryHex: 0x10B981, foregroundHex: 0x047857), // emerald
        .init(primaryHex: 0xEF4444, foregroundHex: 0xB91C1C), // red
        .init(primaryHex: 0x8B5CF6, foregroundHex: 0x6D28D9), // violet
        .init(primaryHex: 0xF59E0B, foregroundHex: 0xB45309), // amber
        .init(primaryHex: 0xEC4899, foregroundHex: 0xBE185D), // pink
        .init(primaryHex: 0x06B6D4, foregroundHex: 0x0E7490), // cyan
        .init(primaryHex: 0x14B8A6, foregroundHex: 0x0F766E), // teal
        .init(primaryHex: 0xF43F5E, foregroundHex: 0xBE123C), // rose
        .init(primaryHex: 0x3B82F6, foregroundHex: 0x1E40AF), // blue
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

/// Indigo circle with a white checkmark — the panel's identity mark.
/// Indigo (#5E6AD2) is the first color in the tag palette, so it sits on-brand.
struct CheckmarkLogo: View {
    var size: CGFloat = 16

    var body: some View {
        Circle()
            .fill(Color(hex: 0x5E6AD2))
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.58, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }
}
