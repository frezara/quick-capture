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

/// The curated Finder-tag hues a section can own (#101's "Sectioned"
/// direction). Which hue a given section gets is decided by
/// `TagHueAssignment`, not by this type — and no longer by hashing the name
/// (#102). The editor no longer carries a copy of this palette either: Swift
/// resolves the hue and pushes it over the bridge.
enum TagPalette {
    struct Entry: Equatable {
        let lightHex: UInt32
        let darkHex: UInt32

        func dot(dark: Bool) -> Color   { Color(hex: dark ? darkHex : lightHex) }
        func label(dark: Bool) -> Color { Color(hex: dark ? darkHex : lightHex) }
        func tint(dark: Bool) -> Color  { Color(hex: dark ? darkHex : lightHex, opacity: dark ? 0.18 : 0.12) }

        /// CSS form, for the pair pushed into the editor.
        var lightCSS: String { String(format: "#%06X", lightHex) }
        var darkCSS:  String { String(format: "#%06X", darkHex) }
    }

    /// Seven hues, in the order they are handed out. Slate was retired in #102:
    /// a grey gives a section no identity, which is the one job the hue has.
    ///
    /// Assignments persist as indices, so the Highlighter retune (THEME.md)
    /// kept each slot's family — coral→rust, magenta→plum, blue→slate-blue,
    /// amber→ochre, indigo→violet — and a section keeps a recognisable colour.
    static let entries: [Entry] = [
        .init(lightHex: 0xA1452B, darkHex: 0xF2A88B), // rust
        .init(lightHex: 0x1F6F74, darkHex: 0x8AD2D5), // teal
        .init(lightHex: 0x8A3B5C, darkHex: 0xE7A3C1), // plum
        .init(lightHex: 0x3B7337, darkHex: 0xA1CF95), // green
        .init(lightHex: 0x3F5F86, darkHex: 0xA9C1E0), // slate-blue
        .init(lightHex: 0x94561C, darkHex: 0xE6B37E), // ochre
        .init(lightHex: 0x6650A0, darkHex: 0xC6B8F0), // violet
    ]

    /// The `cal` command's colour: the calendar wears teal wherever it shows
    /// (tag field, event preview, dropdown glyph), so accent stays interaction.
    static let calendar = entries[1]

    static var count: Int { entries.count }

    static func entry(at index: Int) -> Entry {
        entries[((index % count) + count) % count]
    }
}

/// Which hue each section owns (#102).
///
/// A section takes the **next unused hue the first time it is seen** and keeps
/// it. The map is persisted, so a hue survives a relaunch and does not move
/// when sections above it are added, removed or reordered.
///
/// The rule it replaced hashed the section name. That was stable too, but it
/// clustered: over 17 plausible section names, 9 landed on three near-identical
/// cool hues, one of them a grey — which is most of why a real file read
/// greyscale. Assigning by position in the file separates properly but lets a
/// section's colour move under the user, so the assignment is remembered
/// instead of recomputed.
///
/// A pure value type, so the allocation rule is testable without UserDefaults;
/// `AppState` owns persistence and allocates as it scans the capture file.
struct TagHueAssignment: Codable, Equatable {
    /// Lowercased section name → index into `TagPalette.entries`.
    private(set) var indices: [String: Int]
    /// Section names in the order hues were handed out, oldest first. Only
    /// consulted once every hue is spoken for.
    private(set) var order: [String]

    init(indices: [String: Int] = [:], order: [String] = []) {
        self.indices = indices
        self.order = order
    }

    /// The hue this section owns, or nil if it has never been seen — callers
    /// fall back to the accent, which is what a tag that doesn't exist yet
    /// should look like.
    func index(for tag: String) -> Int? { indices[Self.key(tag)] }

    func entry(for tag: String) -> TagPalette.Entry? {
        index(for: tag).map(TagPalette.entry(at:))
    }

    /// Hand a hue to every tag in `tags` that hasn't got one, in the order
    /// given (which is the order they appear in the capture file). Tags that
    /// already have a hue keep it. Returns true when anything changed, so
    /// callers can skip a needless persist + push.
    @discardableResult
    mutating func assign(_ tags: [String], paletteSize: Int = TagPalette.count) -> Bool {
        guard paletteSize > 0 else { return false }
        var changed = false
        for tag in tags {
            let key = Self.key(tag)
            guard !key.isEmpty, indices[key] == nil else { continue }
            indices[key] = nextHue(paletteSize: paletteSize)
            order.append(key)
            changed = true
        }
        return changed
    }

    /// The next unused hue — or, once all of them are taken, the one whose most
    /// recent assignment is oldest, so a reused hue lands as far from its twin
    /// as the file allows. Ties break on hue index so the result is stable
    /// rather than dictionary-order dependent.
    private func nextHue(paletteSize: Int) -> Int {
        let used = Set(indices.values)
        if let free = (0..<paletteSize).first(where: { !used.contains($0) }) { return free }

        var lastUse: [Int: Int] = [:]
        for (position, key) in order.enumerated() {
            if let hue = indices[key] { lastUse[hue] = position }
        }
        return (0..<paletteSize).min {
            (lastUse[$0] ?? -1, $0) < (lastUse[$1] ?? -1, $1)
        } ?? 0
    }

    /// The hue the capture box's tag field should wear for the tag the typed
    /// text prefix-matches (#104), or nil for the accent treatment.
    ///
    /// Two things get nil deliberately: a tag that isn't a section yet — it has
    /// no identity to show, and the accent doubles as a signal that you're
    /// about to create a section rather than route into one — and `cal`, which
    /// is a command, not a tag.
    func captureFieldEntry(forMatched tag: String?) -> TagPalette.Entry? {
        guard let tag, !Self.isCommand(tag) else { return nil }
        return entry(for: tag)
    }

    /// Capture prefixes that route somewhere other than a section, and so
    /// never take a hue.
    static func isCommand(_ tag: String) -> Bool {
        key(tag) == "cal"
    }

    private static func key(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespaces).lowercased()
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
