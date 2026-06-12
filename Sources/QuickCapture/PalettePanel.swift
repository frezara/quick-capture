import AppKit
import SwiftUI

/// The command palette's own floating panel (epic #82). Unlike
/// `TagDropdownWindow` — a `canBecomeKey: false` child whose keyboard stays in
/// the capture field — the palette **owns** a focused search field, so it must
/// become key. It borrows `TagDropdownPanel`'s borderless `.nonactivatingPanel`
/// mechanics (clear background, shadow, SwiftUI via `NSHostingView`) but is
/// key-capable and centered on the active screen like editor mode.
///
/// `MainPanel` owns the single instance and drives it (`open`/`close`): the
/// summon arrives through `MainPanel.perform(shortcut:)`, and on close the
/// palette must hand key back to `MainPanel` and re-arm its click-away dismiss —
/// both are MainPanel's to manage. The panel is a borderless overlay, not a
/// child window, so losing key while it's up *would* trip MainPanel's
/// self-dismiss; MainPanel suppresses that via `canDismissOnBlur` for the
/// palette's lifetime (see `openPalette`).
final class PalettePanel: NSPanel {
    /// The key difference from `TagDropdownWindow` — the palette holds the
    /// focused search field, so it takes key. It never becomes *main* (it's a
    /// transient overlay, not a document window).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var hosting: NSHostingView<PaletteView>?
    /// Invoked after the panel orders out (Esc, activate, or an external close),
    /// exactly once per open. MainPanel uses it to restore key + re-arm dismiss.
    private var onClose: (() -> Void)?
    /// The row-activation and per-item-action callbacks, retained so `refresh`
    /// can rebuild the SwiftUI view after a mutating action (done/undone, delete)
    /// re-parses the file — same handlers, fresh items.
    private var onActivate: ((PaletteRow) -> Void)?
    private var onItemAction: ((PaletteItemAction) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    var isShowing: Bool { isVisible }

    /// Build the surface, center it on the active screen, and take key. The
    /// `items`/`tagSummary` are the parsed capture file (read by the caller when
    /// the palette opens) — `PaletteView` filters/sorts them via the pure
    /// `PaletteViewModel` as the query changes. The `isDark` flag is resolved
    /// from the panel's effective appearance since a child surface can't read
    /// SwiftUI's environment colour scheme. `onActivate` fires when a row is
    /// chosen (Return/click); `onClose` runs once after the panel hides, however
    /// it was dismissed.
    func open(items: [CaptureItem],
              tagSummary: [CaptureTagSummary],
              onActivate: @escaping (PaletteRow) -> Void,
              onItemAction: @escaping (PaletteItemAction) -> Void,
              onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.onActivate = onActivate
        self.onItemAction = onItemAction

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let host = makeHost(items: items, tagSummary: tagSummary, isDark: isDark)

        // Size to the content, then center on the screen under the cursor (the
        // same screen-selection rule MainPanel uses) so the palette floats over
        // whatever surface is showing.
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = currentScreenVisibleFrame()
        setFrame(NSRect(x: screen.midX - size.width / 2,
                        y: screen.midY - size.height / 2,
                        width: size.width, height: size.height),
                 display: true)

        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    /// Re-render the open palette with freshly parsed items after a mutating
    /// per-item action (done/undone, delete). The disk is canonical, so MainPanel
    /// re-reads + re-parses the file and hands the new items back here; we rebuild
    /// the SwiftUI view with the same retained callbacks so the list reflects the
    /// change without closing the palette. A no-op if the palette isn't showing.
    func refresh(items: [CaptureItem], tagSummary: [CaptureTagSummary]) {
        guard isVisible, hosting != nil else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        _ = makeHost(items: items, tagSummary: tagSummary, isDark: isDark)
    }

    /// Build (or reuse) the hosting view for `items`/`tagSummary`, wiring the
    /// retained `onActivate`/`onItemAction` callbacks. Returns the host so `open`
    /// can size/center it; `refresh` ignores the return.
    @discardableResult
    private func makeHost(items: [CaptureItem],
                          tagSummary: [CaptureTagSummary],
                          isDark: Bool) -> NSHostingView<PaletteView> {
        let view = PaletteView(
            items: items,
            tagSummary: tagSummary,
            isDark: isDark,
            onActivate: { [weak self] row in
                self?.onActivate?(row)
                self?.dismissPalette()
            },
            onItemAction: { [weak self] action in
                // Every per-item action routes out to MainPanel, which owns the
                // disk/editor/pasteboard flows and the post-mutation refresh. The
                // palette stays open so the user can chain actions — MainPanel
                // decides when to dismiss (refile reveals the editor and closes).
                self?.onItemAction?(action)
            },
            onDismiss: { [weak self] in self?.dismissPalette() }
        )
        if let existing = hosting {
            existing.rootView = view
            return existing
        }
        let host = NSHostingView(rootView: view)
        contentView = host
        hosting = host
        return host
    }

    /// Order out and fire `onClose` once. Named `dismissPalette` (not `close`) to
    /// avoid overriding `NSWindow.close`. Safe to call from the SwiftUI handlers
    /// (Esc / activate) or externally; the nil-out guards against a double fire.
    func dismissPalette() {
        guard isVisible else { return }
        orderOut(nil)
        let cb = onClose
        onClose = nil
        cb?()
    }

    private func currentScreenVisibleFrame() -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? self.screen ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
