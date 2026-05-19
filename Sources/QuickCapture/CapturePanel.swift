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

    init(appState: AppState,
         onSubmit: @escaping (String, String?) -> Void,
         onDismiss: @escaping () -> Void) {
        self.appState = appState
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 0),
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
    /// keeping the top edge anchored (panel grows/shrinks downward). Done
    /// manually instead of via NSHostingController.sizingOptions because the
    /// controller's auto-resize path infinite-loops on this borderless
    /// nonactivatingPanel config.
    private func adjustToContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let panelWidth: CGFloat = 600
        let topY = frame.maxY
        let newFrame = NSRect(
            x: frame.minX,
            y: topY - size.height,
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
        // Position roughly 1/3 from the top of the active screen.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        if let screenFrame = screen?.visibleFrame {
            let panelWidth: CGFloat = 600
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.maxY - screenFrame.height / 3
            setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }

        // Order matters: activate the app first so we steal focus from whatever's
        // currently frontmost, then bring the panel forward. `orderFrontRegardless`
        // covers fullscreen / other-space cases where plain activation may race.
        canDismissOnBlur = false
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()

        // Grace period: only after this short delay does losing focus trigger
        // a dismiss. Avoids closing during the initial focus settling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.canDismissOnBlur = true
        }
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
