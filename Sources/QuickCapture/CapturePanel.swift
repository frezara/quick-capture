import AppKit
import SwiftUI

final class CapturePanel: NSPanel {
    private let appState: AppState
    private let onSubmit: (String, String?) -> Void
    private let onDismiss: () -> Void

    /// Guards `resignKey()` from firing during the initial show transition.
    /// macOS shuffles focus around briefly while the panel is becoming key,
    /// so a small grace period prevents an immediate self-dismiss.
    private var canDismissOnBlur = false

    /// Screen-coordinate Y of the desired panel center, captured at show time.
    /// All resizes anchor to this so the panel stays centered regardless of
    /// whether the user pastes (growth) or hides/reshows (height retained
    /// across cycles). Without this, anchoring on `frame.midY` can drift if
    /// SwiftUI emits an intermediate content size before the final layout.
    private var anchorCenterY: CGFloat = 0

    init(appState: AppState,
         onSubmit: @escaping (String, String?) -> Void,
         onDismiss: @escaping () -> Void) {
        self.appState = appState
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss

        // Pre-warm the height to the typical empty-input height so the first
        // show positions the panel near its final size — otherwise the panel
        // briefly appears at height 0 then jumps to the centered position,
        // making the first show feel different from subsequent ones.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        becomesKeyOnlyIfNeeded = false
        appearance = NSAppearance(named: .aqua)   // Paper theme is light
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let root = CaptureView(
            appState: appState,
            onSubmit: { [weak self] text, tag in self?.onSubmit(text, tag) },
            onDismiss: { [weak self] in self?.onDismiss() },
            onContentSizeChange: { [weak self] size in self?.adjustToContentSize(size) }
        )

        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    /// Resize the panel to match the SwiftUI content's intrinsic height while
    /// keeping the vertical center anchored at `anchorCenterY` (set at show
    /// time). Done manually instead of via NSHostingController.sizingOptions
    /// because the controller's auto-resize path infinite-loops on this
    /// borderless nonactivatingPanel config.
    private func adjustToContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let panelWidth: CGFloat = 600
        let newFrame = NSRect(
            x: frame.minX,
            y: anchorCenterY - size.height / 2,
            width: panelWidth,
            height: size.height
        )
        // Skip if effectively unchanged — avoids redundant relayout work.
        guard abs(newFrame.height - frame.height) > 0.5 else { return }
        setFrame(newFrame, display: true, animate: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        // Capture the active screen's vertical center and anchor every resize
        // (and the initial positioning) to it. Storing this separately from
        // frame.midY keeps the position deterministic across hide/show cycles.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        if let screenFrame = screen?.visibleFrame {
            let panelWidth: CGFloat = 600
            anchorCenterY = screenFrame.midY
            // Force SwiftUI to layout now so frame.height reflects the actual
            // content size, not the stale init/previous value. Without this,
            // the panel is positioned for the wrong height and only re-centers
            // after the first ContentSizeKey fire — a visible jump on show.
            contentView?.layoutSubtreeIfNeeded()
            let x = screenFrame.midX - panelWidth / 2
            let y = anchorCenterY + frame.height / 2
            setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }

        // Order matters: activate the app first so we steal focus from whatever's
        // currently frontmost, then bring the panel forward. `orderFrontRegardless`
        // covers fullscreen / other-space cases where plain activation may race.
        canDismissOnBlur = false
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()

        // Focus the todo input. Done from the panel side (rather than relying on
        // SwiftUI's @FocusState → Binding<Bool> path) because that races with
        // the panel-becoming-key transition and the first responder can land
        // back on the panel itself.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let textView = self.firstTextView(in: self.contentView) else { return }
            self.makeFirstResponder(textView)
        }

        // Grace period: only after this short delay does losing focus trigger
        // a dismiss. Avoids closing during the initial focus settling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.canDismissOnBlur = true
        }
    }

    private func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view = view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let tv = firstTextView(in: sub) { return tv }
        }
        return nil
    }

    override func orderOut(_ sender: Any?) {
        canDismissOnBlur = false
        super.orderOut(sender)
    }

    override func resignKey() {
        super.resignKey()
        guard canDismissOnBlur else { return }
        canDismissOnBlur = false
        onDismiss()
    }
}
