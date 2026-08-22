import AppKit
import SwiftUI

/// The tag-suggest dropdown lives in a borderless child window attached to
/// the capture panel, positioned under the tag field (#70). A SwiftUI overlay
/// can't do this job: the capture window is content-sized, so anything
/// rendered past its bottom edge is clipped — and growing the window to fit
/// (the first implementation) ballooned the whole panel. A child window
/// floats over whatever is behind the panel without resizing it.
///
/// The window never becomes key — keyboard interaction stays in the capture
/// panel's tag field (CaptureView handles ↑/↓/Enter/Tab/Esc); this surface
/// only renders the list and takes row clicks.
final class TagDropdownWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Zero-sized view layered behind the tag field purely to learn its frame.
/// The coordinator owns the child window's lifecycle: shown/sized/positioned
/// from `updateNSView`, repositioned when the parent panel moves or resizes
/// (content growth resizes the window, so the field's screen rect shifts even
/// though SwiftUI state didn't change).
struct TagDropdownAnchor: NSViewRepresentable {
    var tags: [String]
    var highlight: Int
    var visible: Bool
    var isDark: Bool
    /// Section hues (#102). Passed in rather than derived: the hue is now
    /// allocated state owned by AppState, not a function of the tag name.
    var hues: TagHueAssignment
    var onPick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // Deferred: during the first layout pass the view isn't in a window
        // yet, and AppKit dislikes window mutations mid-layout.
        let coordinator = context.coordinator
        let (tags, highlight, visible, isDark, hues, onPick) = (tags, highlight, visible, isDark, hues, onPick)
        DispatchQueue.main.async {
            coordinator.update(anchor: view, tags: tags, highlight: highlight,
                               visible: visible, isDark: isDark, hues: hues, onPick: onPick)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator {
        private var window: TagDropdownWindow?
        private var hosting: NSHostingView<TagDropdownContent>?
        private weak var anchor: NSView?
        private var observers: [NSObjectProtocol] = []

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        func update(anchor: NSView, tags: [String], highlight: Int, visible: Bool,
                    isDark: Bool, hues: TagHueAssignment, onPick: @escaping (String) -> Void) {
            self.anchor = anchor
            guard visible, !tags.isEmpty, let parent = anchor.window, parent.isVisible else {
                close()
                return
            }

            let content = TagDropdownContent(tags: tags, highlight: highlight,
                                             isDark: isDark, hues: hues, onPick: onPick)
            if let hosting {
                hosting.rootView = content
            } else {
                let w = TagDropdownWindow(
                    contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                w.backgroundColor = .clear
                w.isOpaque = false
                w.hasShadow = true
                w.isReleasedWhenClosed = false
                w.animationBehavior = .none
                let h = NSHostingView(rootView: content)
                w.contentView = h
                hosting = h
                window = w
            }
            guard let window, let hosting else { return }

            if window.parent !== parent {
                window.parent?.removeChildWindow(window)
                parent.addChildWindow(window, ordered: .above)
            }
            let height = hosting.fittingSize.height
            window.setFrame(frameUnderAnchor(anchor, parent: parent, height: height), display: true)
            window.orderFront(nil)
            window.invalidateShadow()
            observeParent(parent)
        }

        func close() {
            guard let window else { return }
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }

        /// Right-aligned under the tag field, 6pt gap. Screen coordinates —
        /// y grows upward, so "below" means subtracting the height.
        private func frameUnderAnchor(_ anchor: NSView, parent: NSWindow, height: CGFloat) -> NSRect {
            let width: CGFloat = 180
            let inWindow = anchor.convert(anchor.bounds, to: nil)
            let onScreen = parent.convertToScreen(inWindow)
            return NSRect(x: onScreen.maxX - width,
                          y: onScreen.minY - 6 - height,
                          width: width,
                          height: height)
        }

        private func observeParent(_ parent: NSWindow) {
            guard observers.isEmpty else { return }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: parent, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                })
            }
        }

        private func reposition() {
            guard let window, window.isVisible, let anchor, let parent = anchor.window else { return }
            let height = window.frame.height
            window.setFrame(frameUnderAnchor(anchor, parent: parent, height: height), display: true)
        }
    }
}

/// The dropdown card itself — rendered inside the child window, so it can't
/// read CaptureView's environment; the dark flag is passed in explicitly.
struct TagDropdownContent: View {
    var tags: [String]
    var highlight: Int
    var isDark: Bool
    var hues: TagHueAssignment
    var onPick: (String) -> Void

    private var theme: Theme { isDark ? .dark : .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                row(tag, highlighted: index == highlight)
                    .onTapGesture { onPick(tag) }
            }
        }
        .padding(3)
        // Floating card — opaque surface, not the translucent well tint
        // (same lesson as the editor's refile dropdown, 56b274f).
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 0.5)
        )
        .frame(width: 180)
    }

    private func row(_ name: String, highlighted: Bool) -> some View {
        let isCal = name.lowercased() == "cal"
        // No hue means the tag isn't a section in the capture file yet, so it
        // has no identity to show — the dot is simply absent rather than
        // guessed at. `cal` is a command, not a tag, and keeps its glyph.
        let hue = hues.entry(for: name)
        return HStack(spacing: 6) {
            if isCal {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.inkTertiary)
            } else if let hue {
                Circle()
                    .fill(hue.dot(dark: isDark))
                    .frame(width: 7, height: 7)
            } else {
                Circle()
                    .fill(theme.inkTertiary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
            Text(name)
                .foregroundStyle(highlighted ? theme.accentInk : theme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(TypeScale.chip)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(highlighted ? AnyShapeStyle(theme.accentSoft) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .help(isCal ? "Creates a calendar event — type naturally, e.g. \"call Seb tomorrow at 2pm\"" : "")
    }
}
