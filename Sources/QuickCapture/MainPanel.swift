import AppKit
import Darwin
import SwiftUI
import WebKit

/// The standard editing chords AppKit normally dispatches through the Edit menu.
/// Capture mode runs as `.accessory` with no menu bar (only editor mode bumps to
/// `.regular`), so ⌘V/⌘C/⌘X/⌘A would be dropped — `MainPanel` sends them down the
/// responder chain itself (#78). Bare ⌘ only: ⌘⇧V and friends aren't ours.
enum CaptureEditingChord {
    static func selector(key: String?, modifiers: NSEvent.ModifierFlags) -> Selector? {
        guard modifiers == .command else { return nil }
        switch key {
        case "v": return #selector(NSText.paste(_:))
        case "c": return #selector(NSText.copy(_:))
        case "x": return #selector(NSText.cut(_:))
        case "a": return #selector(NSText.selectAll(_:))
        default:  return nil
        }
    }
}

/// The single floating panel that hosts both app surfaces — the capture box and
/// the CodeMirror markdown editor — as **mutually-exclusive modes** (ADR-0004).
/// Both stay mounted (the editor's web view is kept warm); ⌥⌘I crossfades
/// between them while animating the window frame, so exactly one is visible.
///
/// Behaviors keyed to whether the editor is open (`editorOpen`):
/// - **Click-away dismiss** only fires in capture mode (`resignKey`); the
///   editor survives losing focus so you can copy from other apps.
///   `canDismissOnBlur` guards against false fires during transitions.
/// - **⌥⌘I** is intercepted in `performKeyEquivalent`, toggling the mode.
///   ⌘F passes through to CodeMirror's search panel (native find), and ⌘R is
///   swallowed in editor mode so WebKit can't reload the warm editor. All
///   window-level bindings live in `ShortcutRegistry`.
/// - **Activation policy** is `.regular` while the editor is open so the
///   standard menu bar (⌘C/V/Z…) works, then `.accessory` when collapsed.
/// - **Disk is canonical, one writer by mutual exclusion:** capture-mode
///   submits write straight to disk via `FileWriter`; the editor flushes its
///   debounced save (`flushEditorSave`) before leaving editor mode, and the
///   file watcher reloads the warm editor on external changes.
final class MainPanel: NSPanel {
    private let appState: AppState
    private let onSubmit: (String, String?, [URL]) -> Bool
    private let onDismiss: () -> Void

    private(set) var editorOpen = false
    private(set) var workspaceOpen = false
    private lazy var workspaceModel = WorkspaceModel(appState: appState)
    private var workspaceHost: NSHostingView<WorkspaceView>?

    /// True while the screenshot picker takeover surface is shown (a large
    /// centered frame, capture inputs hidden — same window, like editor mode).
    /// Guards `captureContentDidChange` from fighting the fixed picker frame.
    private(set) var pickerOpen = false

    // MARK: Surfaces

    private let container = PanelContainerView()
    private var captureHost: NSHostingView<CaptureView>!
    private let editorContainer = EditorContainerView()
    private let webView: WKWebView
    private let bridge = EditorBridge()

    // MARK: Capture sizing

    /// Screen-coordinate Y of the desired panel center, captured at show time.
    /// Input-only resizes anchor to this so the box stays centered as it grows
    /// with multi-line input.
    private var anchorCenterY: CGFloat = 0
    /// Latest intrinsic size reported by `CaptureView`. Drives the input-only
    /// window height, and the split's top-strip height.
    private var captureContentSize: CGSize = CGSize(width: 600, height: 100)

    /// Guards `resignKey()` from self-dismissing during the show transition.
    private var canDismissOnBlur = false

    /// The app that was frontmost when the panel was summoned, so focus can
    /// return to it on dismiss — the capture flow should be a zero-cost
    /// interruption. Recorded on every fresh summon (capture or editor) before
    /// we activate ourselves; cleared once restored.
    private var previousApp: NSRunningApplication?

    // MARK: Editor file state

    /// File currently loaded in the editor. Always the capture file; tracked so
    /// a path change in Settings re-points the watcher on the next editor entry.
    private var loadedFileURL: URL
    /// Last content we wrote to disk or pushed to the editor — lets the watcher
    /// ignore our own writes instead of looping them back as external changes.
    private var lastSyncedContent = ""
    private var editorFileLoaded = false
    private var exitPending = false
    private var webViewReady = false
    private var fileWatcher: DispatchSourceFileSystemObject?
    /// The ⌥⌘O picker is overlaying the editor (#126) rather than growing the
    /// capture window. Distinct from `pickerOpen`, which drives the capture-mode
    /// takeover and its frame animation.
    private var pickerOverEditor = false
    private var hotKeyObserver: NSObjectProtocol?
    private var vimObserver: NSObjectProtocol?
    private var refileTargetsObserver: NSObjectProtocol?
    private var tagHuesObserver: NSObjectProtocol?
    /// True for the duration of the editor→capture collapse animation, so
    /// `captureContentDidChange` defers window geometry to the animation.
    private var isCollapsing = false
    /// Set when the screenshot picker closes: the next capture re-measure (the
    /// box may now be taller — the preview band appears when a shot is attached)
    /// drives a centered animated shrink instead of the usual top-anchored snap.
    private var recenterCaptureAfterPicker = false
    /// Incremented on every fresh summon or ⌥⌘O; completion blocks capture it
    /// so stale completions from a prior summon cannot resurrect a detached chip.
    private var attachLookupGeneration = 0

    private let splitWidth: CGFloat = 1120
    private let captureWidth: CGFloat = 680

    deinit {
        stopWatching()
        if let hotKeyObserver { NotificationCenter.default.removeObserver(hotKeyObserver) }
        if let vimObserver { NotificationCenter.default.removeObserver(vimObserver) }
        if let refileTargetsObserver { NotificationCenter.default.removeObserver(refileTargetsObserver) }
        if let tagHuesObserver { NotificationCenter.default.removeObserver(tagHuesObserver) }
    }

    init(appState: AppState,
         onSubmit: @escaping (String, String?, [URL]) -> Bool,
         onDismiss: @escaping () -> Void) {
        self.appState = appState
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self.loadedFileURL = appState.captureFileURL

        // navigator.clipboard.readText() (vim's `p`) is blocked unless these
        // private prefs are flipped via KVC — the Swift API doesn't expose them.
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "javaScriptCanAccessClipboard")
        config.preferences.setValue(true, forKey: "DOMPasteAllowed")
        self.webView = WKWebView(frame: .zero, configuration: config)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: captureWidth, height: 100),
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
        // Follow the system appearance (drives the Misted-Steel light/dark
        // pair). Previously pinned to .aqua, which forced the UI light.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        setupContainer()
        bridge.panel = self
        config.userContentController.add(bridge, name: "editorBridge")
        loadEditor()

        hotKeyObserver = NotificationCenter.default.addObserver(forName: .hotKeyDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.pushEditorKeymap()
        }

        // Live-toggle vim in the editor when the setting changes.
        vimObserver = NotificationCenter.default.addObserver(
            forName: .vimModeDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.pushVimSetting() }

        // Refile targets edited in Settings take effect in the editor's ⌥⌘U
        // dropdown without a restart (R35) — the editor can't read settings, so
        // we re-push the effective list whenever it changes.
        refileTargetsObserver = NotificationCenter.default.addObserver(
            forName: .refileTargetsDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.pushRefileTargets() }

        // A new section allocates a hue (#102), which the editor can't derive
        // for itself — re-push whenever the map grows.
        tagHuesObserver = NotificationCenter.default.addObserver(
            forName: .tagHuesDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.pushTagHues() }
    }

    private func setupContainer() {
        // Start surfaces at the real capture size so AppKit's first
        // resize-to-content-rect (on `contentView = container`) is a no-op rather
        // than a degenerate scale-up from `.zero`.
        let initialFrame = NSRect(x: 0, y: 0, width: captureWidth, height: 100)
        container.frame = initialFrame
        container.captureHeight = captureContentSize.height

        captureHost = NSHostingView(rootView: makeCaptureView())
        captureHost.wantsLayer = true
        captureHost.frame = initialFrame
        // Capture mode: the host fills the window so its SwiftUI content measures
        // correctly and drives the window height. PanelContainerView centres it
        // at a fixed size only while the editor is the active surface.
        captureHost.autoresizingMask = [.width, .height]

        editorContainer.frame = initialFrame
        editorContainer.autoresizingMask = [.width, .height]
        editorContainer.isHidden = true
        editorContainer.alphaValue = 0

        webView.setValue(false, forKey: "drawsBackground")   // no white flash on load
        editorContainer.configure(web: webView)

        container.configure(capture: captureHost, editor: editorContainer)
        contentView = container
    }

    /// Builds the capture surface. @State (typed text, focus) survives a rebuild
    /// because NSHostingView preserves the SwiftUI graph across rootView updates
    /// of the same view type.
    private func makeCaptureView() -> CaptureView {
        CaptureView(
            appState: appState,
            // Capture and editor are mutually exclusive (ADR-0004), so a
            // submit always writes straight to disk, the canonical copy.
            onSubmit: { [weak self] text, tag, attachments in self?.onSubmit(text, tag, attachments) ?? false },
            onClose: { [weak self] in self?.dismiss() },
            onToggleEditor: { [weak self] in self?.toggleEditor() },
            onEscape: { [weak self] in self?.handleEscape() },
            onContentSizeChange: { [weak self] size in self?.captureContentDidChange(size) },
            onPickerAttach: { [weak self] urls in self?.pickerDidFinish(attaching: urls) },
            onPickerCancel: { [weak self] in self?.pickerDidFinish(attaching: nil) },
            onHintAction: { [weak self] action in self?.perform(shortcut: action) }
        )
    }

    // MARK: - Presentation

    /// ⌥⌘P — the home key. From any surface it lands on the capture box, and it
    /// gets there through the same exits the toggles use (#124): `closeEditor()`
    /// flushes the editor's pending save (ADR-0004) and crossfades, and the
    /// picker shrinks back animated. It used to reset that state underneath
    /// them, which skipped both — and skipping the flush is a data-loss race,
    /// since the web view is never torn down and its queued save can land after
    /// a capture has been written.
    func show() {
        recordPreviousApp()   // before NSApp.activate steals frontmost from it

        if workspaceOpen { closeWorkspace(); return }
        if editorOpen {
            closeEditor()     // handles activate, focus and the dismiss guard
            return
        }
        if pickerOpen {
            // Cancel, don't attach — same as a second ⌥⌘O or Esc. The recenter
            // animation restores focus and re-arms click-away dismiss.
            closePickerSurface(attaching: nil)
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            return
        }
        if isVisible {
            // Already home. Bring it forward and focus, but leave a capture in
            // progress alone: R20's clean slate is about a *fresh* summon, and
            // wiping here would discard typed text and attachments that ⌥⌘I
            // preserves.
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            orderFrontRegardless()
            focusCapture()
            return
        }

        // Fresh summon from hidden — the one path that starts clean (R20).
        collapseStateReset()
        resetCaptureAttachments()
        if let screen = currentScreenVisibleFrame() {
            anchorCenterY = screen.midY
            var f = frame
            f.size.width = captureWidth
            setFrame(f, display: false)
            // Force layout so frame.height reflects real content size before we
            // position — otherwise the first show jumps after the size report.
            container.layoutSubtreeIfNeeded()
            let x = screen.midX - captureWidth / 2
            let y = anchorCenterY + frame.height / 2
            setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }
        canDismissOnBlur = false
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        focusCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.canDismissOnBlur = true
        }
    }

    /// Center the workspace and keep it inside the active screen’s usable area.
    private func splitFrame(in screen: NSRect) -> NSRect {
        let width = min(splitWidth, screen.width - 40)
        let height = min(820, screen.height - 40)
        return NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2,
                      width: width, height: height)
    }

    /// Summon straight into the editor split, without the grow animation.
    /// `animated` morphs the frame instead of snapping — for handing off from a
    /// visible takeover (e.g. the screenshot picker), so the editor's frame
    /// visibly takes over rather than the old surface's frame lingering for a
    /// beat. (Currently unused — the editor is entered via ⌥⌘I `toggleEditor` —
    /// kept as the direct summon-into-editor entry point.)
    func showInEditor(animated: Bool = false) {
        recordPreviousApp()   // before promote/activate steals frontmost from it
        editorOpen = true
        isMovableByWindowBackground = false
        promoteToRegular()
        reconcileEditorFile()
        container.editorActive = true
        editorContainer.isHidden = false
        captureHost.alphaValue = 0
        canDismissOnBlur = false
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        guard let screen = currentScreenVisibleFrame() else {
            editorContainer.alphaValue = 1
            focusEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.canDismissOnBlur = true
            }
            return
        }
        let target = splitFrame(in: screen)
        anchorCenterY = target.midY
        if animated {
            // The editor surface starts transparent and fades up as the window
            // morphs from the (just-vacated) takeover frame to the split frame —
            // the editor owns the final geometry, no stale takeover frame flashes.
            editorContainer.alphaValue = 0
            animateFrame(to: target, fadeEditorTo: 1) { [weak self] in
                self?.focusEditor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.canDismissOnBlur = true
                }
            }
        } else {
            editorContainer.alphaValue = 1
            setFrame(target, display: false)
            focusEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.canDismissOnBlur = true
            }
        }
    }

    // MARK: - Open / close

    func toggleEditor() {
        editorOpen ? closeEditor() : openEditor()
    }

    /// Switch to editor mode: crossfade the capture box out and the full editor
    /// in while the window grows to the editor frame.
    func openEditor() {
        guard !editorOpen, !exitPending else { return }
        workspaceHost?.isHidden = true
        captureHost.isHidden = false
        workspaceOpen = false
        editorOpen = true
        // The picker is a capture-surface affordance; ⌥⌘I into the editor closes
        // it. editorOpen is set first so the capture re-measure this triggers is
        // already guarded; openEditor's own animateFrame places the geometry.
        pickerOpen = false
        appState.screenshotPickerItems = nil
        isMovableByWindowBackground = false
        promoteToRegular()
        NSApp.activate(ignoringOtherApps: true)
        reconcileEditorFile()

        container.editorActive = true   // capture box → centred fixed box (won't stretch)
        editorContainer.isHidden = false
        editorContainer.alphaValue = 0

        guard let screen = currentScreenVisibleFrame() else { return }
        let target = splitFrame(in: screen)
        anchorCenterY = target.midY
        animateFrame(to: target, fadeEditorTo: 1) { [weak self] in
            self?.focusEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.canDismissOnBlur = true
            }
        }
    }

    /// Switch to capture mode: crossfade the editor out and the capture box in
    /// while the window shrinks back to the centered capture box.
    func closeEditor() {
        guard editorOpen, !exitPending else { return }
        exitPending = true
        flushEditorSave { [weak self] saved in
            guard let self else { return }
            self.exitPending = false
            if saved { self.finishClosingEditor() }
        }
    }

    private func finishClosingEditor() {
        // The overlay is an editor-mode affordance, so leaving cancels it —
        // mirroring openEditor()'s cancel of the capture-mode picker. The
        // crossfade below owns the alphas, so this only clears state.
        cancelPickerOverEditor()
        editorOpen = false
        isCollapsing = true
        isMovableByWindowBackground = true

        guard let screen = currentScreenVisibleFrame() else { return }
        anchorCenterY = screen.midY
        let target = NSRect(x: screen.midX - captureWidth / 2,
                            y: screen.midY - container.captureHeight / 2,
                            width: captureWidth, height: container.captureHeight)
        animateFrame(to: target, fadeEditorTo: 0) { [weak self] in
            guard let self else { return }
            // Window is back to capture size; hand the capture host back to its
            // fill/measure behavior and hide the editor.
            self.container.editorActive = false
            self.editorContainer.isHidden = true
            // The web view held first responder under `.regular`; drop back to
            // `.accessory` and re-establish key/active before focusing, else
            // `makeFirstResponder` lands on a non-key panel and the field gets
            // no editing focus.
            self.isCollapsing = false
            self.demoteToAccessory()
            NSApp.activate(ignoringOtherApps: true)
            self.makeKeyAndOrderFront(nil)
            self.orderFrontRegardless()
            self.focusCapture()
            // Arm click-away dismiss only after the .regular→.accessory switch
            // settles. That policy change makes the panel transiently resign key,
            // which would otherwise be read as a click-away and dismiss the
            // freshly-shown capture box. Mirrors show()'s guard window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.canDismissOnBlur = true
            }
        }
    }

    /// Animate the window frame while crossfading the two surfaces: the editor
    /// fades to `alpha`, the capture box to its complement, so exactly one is
    /// visible at rest (mutually-exclusive modes, ADR-0004).
    private func animateFrame(to targetFrame: NSRect,
                              fadeEditorTo alpha: CGFloat,
                              completion: @escaping () -> Void) {
        canDismissOnBlur = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(targetFrame, display: true)
            editorContainer.animator().alphaValue = alpha
            captureHost.animator().alphaValue = 1 - alpha
        }, completionHandler: completion)
    }

    private func collapseStateReset() {
        captureHost.isHidden = false
        workspaceOpen = false
        workspaceHost?.isHidden = true
        cancelPickerOverEditor()
        editorOpen = false
        pickerOpen = false
        isCollapsing = false   // a fresh summon cancels any in-flight collapse
        container.editorActive = false
        editorContainer.isHidden = true
        editorContainer.alphaValue = 0
        captureHost.alphaValue = 1
        isMovableByWindowBackground = true
        demoteToAccessory()
    }

    // MARK: - Native workspace

    func openWorkspace(_ destination: WorkspaceDestination) {
        guard !exitPending, !isCollapsing else { return }
        if editorOpen {
            exitPending = true
            flushEditorSave { [weak self] saved in
                guard let self else { return }
                self.exitPending = false
                guard saved else { return }
                self.cancelPickerOverEditor()
                self.editorOpen = false
                self.openWorkspace(destination)
            }
            return
        }
        workspaceOpen = true
        pickerOpen = false
        attachLookupGeneration += 1
        appState.screenshotPickerItems = nil
        canDismissOnBlur = false
        workspaceModel.navigate(destination)
        if workspaceHost == nil {
            let host = NSHostingView(rootView: WorkspaceView(model: workspaceModel,
                onCapture: { [weak self] in self?.closeWorkspace() },
                onEditor: { [weak self] in self?.openEditor() },
                onProjectCapture: { [weak self] id in
                    self?.appState.captureProjectID = id
                    self?.closeWorkspace()
                }))
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            workspaceHost = host
        }
        container.editorActive = true
        captureHost.alphaValue = 0
        captureHost.isHidden = true
        editorContainer.isHidden = true
        workspaceHost?.isHidden = false
        isMovableByWindowBackground = false
        promoteToRegular()
        if let screen = currentScreenVisibleFrame() { setFrame(splitFrame(in: screen), display: true, animate: true) }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(workspaceHost)
    }

    private func closeWorkspace() {
        guard workspaceOpen else { return }
        canDismissOnBlur = false
        workspaceOpen = false
        workspaceHost?.isHidden = true
        captureHost.isHidden = false
        container.editorActive = false
        captureHost.alphaValue = 1
        isMovableByWindowBackground = true
        if let screen = currentScreenVisibleFrame() {
            let height = captureContentSize.height
            setFrame(NSRect(x: screen.midX - captureWidth / 2, y: screen.midY - height / 2,
                            width: captureWidth, height: height), display: true, animate: true)
        }
        demoteToAccessory()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        focusCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.canDismissOnBlur = true
        }
    }

    // MARK: - Frames

    private func currentScreenVisibleFrame() -> NSRect? {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? self.screen ?? NSScreen.main
        return screen?.visibleFrame
    }

    /// Capture mode: resize the window to the capture content height (top edge
    /// fixed, growing downward). Editor mode: just record the height — the window
    /// keeps its full editor frame; the (hidden) capture box stays centred at the
    /// recorded size so it dissolves in place on the next switch.
    private func captureContentDidChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // The picker takeover fills the window; ignore those measurements. Keying
        // off the live surface (not `pickerOpen`) means that once the items clear
        // the swapped-back capture box reports its real height even while the
        // close animation still has `pickerOpen` set — so we size to the box's
        // post-attach height (with the preview band) rather than the stale one.
        guard appState.screenshotPickerItems == nil else { return }
        captureContentSize = size
        container.captureHeight = size.height
        guard !editorOpen, !workspaceOpen else { return }
        // The picker just closed: re-center and shrink to the box's fresh height
        // (taller when a shot was attached). Owns the frame for this transition.
        if recenterCaptureAfterPicker {
            recenterCaptureAfterPicker = false
            animateCaptureRecenter(toHeight: size.height)
            return
        }
        // While collapsing editor→capture, or while the picker-close animation is
        // still running (pickerOpen set), the frame animation owns the window
        // geometry. Without this, the re-measure that closeEditor triggers (it
        // sets editorOpen=false, so we'd reach here) fires a non-animated
        // setFrame to a box at the editor's edge — which then animates to centre,
        // reading as "shrink to the side, then re-centre". Record the size for
        // the animation target; let the animation place the frame.
        guard !isCollapsing, !pickerOpen else { return }
        // Keep the top edge fixed and grow/shrink *downward*, tracking the
        // content's SwiftUI-animated height each frame so the window moves in
        // lockstep with the footer — smooth and symmetric. Recentering (the old
        // anchorCenterY − h/2) made the header drift up mid-animation, which is
        // what read as jank.
        let f = NSRect(x: frame.minX,
                       y: frame.maxY - size.height,
                       width: captureWidth,
                       height: size.height)
        guard abs(f.height - frame.height) > 0.5 else { return }
        setFrame(f, display: true, animate: false)
    }

    // MARK: - Activation policy

    private func promoteToRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    private func demoteToAccessory() {
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: - Previous-app focus

    /// Snapshot the frontmost app at summon time so a dismiss can hand focus
    /// back to it. Skipped (and the slot cleared) when we're already frontmost,
    /// so a re-summon can't record ourselves as the app to return to.
    private func recordPreviousApp() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        // Keep what we already had when we're the frontmost app: ⌥⌘P pressed
        // from inside the editor must not erase the app Esc returns you to
        // (#124). Editor mode runs `.regular`, so we ARE frontmost there.
        guard front?.processIdentifier != myPID else { return }
        previousApp = front
    }

    /// True when *we* are the app currently holding focus (or nothing is). Read
    /// this BEFORE hiding the panel — `orderOut` shifts the frontmost app, after
    /// which the check is meaningless.
    private var weHoldFocus: Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        return front == nil || front?.processIdentifier == myPID
    }

    /// On a full dismiss, return focus to the app the user came from — but only
    /// when `weHeldFocus` (captured before we hid). If the user switched to a
    /// third app while the panel was up, that app is now frontmost and we leave
    /// it be rather than yanking focus back. Call *after* demoting to
    /// `.accessory` (the policy switch itself reshuffles activation).
    private func restorePreviousApp(weHeldFocus: Bool) {
        defer { previousApp = nil }
        guard weHeldFocus, let previousApp, !previousApp.isTerminated else { return }
        previousApp.activate()
    }

    // MARK: - Focus

    /// Focus the capture input. On first launch the SwiftUI hosting view often
    /// hasn't instantiated the editor's NSTextView yet (and the panel may not be
    /// key), so a single attempt silently no-ops. Force a layout pass to realize
    /// the text view, then retry briefly until `makeFirstResponder` takes.
    private func focusCapture(retriesLeft: Int = 10) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.editorOpen, !self.workspaceOpen else { return }
            if self.isVisible {
                self.captureHost.layoutSubtreeIfNeeded()
                if let tv = self.firstTextView(in: self.captureHost), self.makeFirstResponder(tv) {
                    return
                }
            }
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.focusCapture(retriesLeft: retriesLeft - 1)
            }
        }
    }

    private func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editorOpen, !self.workspaceOpen else { return }
            self.makeFirstResponder(self.webView)
            self.webView.evaluateJavaScript("window.qcEditor && window.qcEditor.focus && window.qcEditor.focus()",
                                            completionHandler: nil)
        }
    }

    private func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let tv = firstTextView(in: sub) { return tv }
        }
        return nil
    }

    // MARK: - Capture routing

    /// Esc from the capture box dismisses. (In editor mode, Esc is handled inside
    /// the web view — vim, or the dismiss binding when vim is off — not here.)
    private func handleEscape() { dismiss() }

    /// Fully dismiss the panel. Flushes the editor's pending save first so disk
    /// is current, then hands off to the dismiss closure (which hides the panel
    /// and clears any preserved capture text).
    func dismiss() {
        if appState.captureRecoveryBlocked {
            let alert = NSAlert()
            alert.messageText = "The failed capture could not be backed up"
            alert.informativeText = "Keep this panel open and copy or save the text before dismissing it."
            alert.runModal()
            return
        }
        guard !exitPending else { return }
        exitPending = true
        flushEditorSave { [weak self] saved in
            guard let self else { return }
            self.exitPending = false
            if saved { self.onDismiss() }
        }
    }

    /// Esc in the editor with vim off (posted from editor.ts via the bridge).
    fileprivate func dismissFromEditor() { dismiss() }

    // MARK: - Screenshot attach

    /// A fresh summon (R20) starts with a clean capture box — no attachment,
    /// picker, or feedback state carried over from a prior session, and never on
    /// the ⌥⌘I editor return. Screenshots attach explicitly via the ⌥⌘O picker;
    /// there is no auto-attach. Bumping the lookup generation invalidates any
    /// in-flight ⌥⌘O lookup whose completion might otherwise land here.
    private func resetCaptureAttachments() {
        attachLookupGeneration += 1
        appState.pendingAttachments = []
        appState.attachFeedback = nil
        appState.screenshotPickerItems = nil
    }

    /// ⌥⌘O — open the screenshot picker takeover surface with the 10 most
    /// recent screenshots (newest pre-highlighted). Picking one attaches it as
    /// the chip; Esc closes without changing the attachment. No screenshots →
    /// the transient "No screenshots found" feedback instead of an empty panel.
    func openScreenshotPicker() {
        attachLookupGeneration += 1
        let generation = attachLookupGeneration
        ScreenshotLocator.recent(limit: 10) { [weak self] result in
            guard let self, generation == self.attachLookupGeneration else { return }
            let report: (String) -> Void = { message in
                if self.editorOpen {
                    self.appState.screenshotPickerItems = nil
                    self.editorToast(message)
                } else {
                    self.appState.screenshotPickerItems = nil
                    self.appState.attachFeedback = message
                }
            }
            if result.accessDenied {
                // Spotlight may still have returned names, but every thumbnail
                // would be a placeholder — the actionable hint wins over both the
                // empty state and the broken-looking list.
                report("Quick Capture needs Desktop access — System Settings → Privacy & Security → Files & Folders")
            } else if result.screenshots.isEmpty {
                report("No screenshots found")
            } else {
                self.appState.screenshotPickerItems = result.screenshots
                if self.editorOpen {
                    self.enterPickerOverEditor()
                } else {
                    self.enterPickerSurface()
                }
            }
        }
    }

    /// Editor-style geometry for the picker: a comfortable centered panel, wider
    /// than the capture box and a generous fraction of the screen height.
    private func pickerFrame(in screen: NSRect) -> NSRect {
        let width: CGFloat = min(860, screen.width - 80)
        let height: CGFloat = min(560, screen.height * 0.82)
        return NSRect(x: screen.midX - width / 2,
                      y: screen.midY - height / 2,
                      width: width, height: height)
    }

    /// Grow the window to the centered picker frame. The capture host stays the
    /// active surface (CaptureView swaps its own content to the picker), so no
    /// crossfade host is involved — just the frame animation.
    private func enterPickerSurface() {
        guard !pickerOpen, !editorOpen, let screen = currentScreenVisibleFrame() else { return }
        pickerOpen = true
        canDismissOnBlur = false
        let target = pickerFrame(in: screen)
        anchorCenterY = target.midY
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.canDismissOnBlur = true }
        })
    }

    /// Close the picker surface, optionally attaching `urls` as the chips, and
    /// shrink back to the centered capture box. Clearing the items swaps the box
    /// back; its fresh measurement drives the centered animated shrink via
    /// `recenterCaptureAfterPicker` — so the window ends at the box's *post-attach*
    /// height (taller when the preview band appears), not the stale pre-picker one.
    /// `pickerOpen` stays true until that animation finishes, so a second ⌥⌘O
    /// during the shrink doesn't re-open the picker.
    private func closePickerSurface(attaching urls: [URL]?) {
        // nil = cancel (leave the current attachments untouched); a non-nil list
        // replaces them with the picker's selection (R: ⌥⌘O sets the chips).
        if let urls { appState.pendingAttachments = urls }
        guard pickerOpen else { appState.screenshotPickerItems = nil; return }
        canDismissOnBlur = false
        recenterCaptureAfterPicker = true
        appState.screenshotPickerItems = nil
    }

    /// Which surface the picker was on decides what "attach" means: capture
    /// mode fills the capture box's chips, editor mode attaches to the item
    /// under the cursor (#126).
    private func pickerDidFinish(attaching urls: [URL]?) {
        if pickerOverEditor {
            closePickerOverEditor(attaching: urls)
        } else {
            closePickerSurface(attaching: urls)
        }
    }

    /// Show the picker over the editor. The capture host already renders the
    /// picker whenever items are set, so it comes forward full-bleed with the
    /// editor behind it — no frame animation, since the window keeps the
    /// editor's geometry and this should read as a sheet rather than a resize.
    private func enterPickerOverEditor() {
        guard editorOpen, !pickerOverEditor else { return }
        pickerOverEditor = true
        canDismissOnBlur = false
        container.pickerOverEditor = true
        captureHost.alphaValue = 1
        editorContainer.alphaValue = 0
        // The web view holds first responder in editor mode; hand it to the
        // capture host so CaptureView's root key handlers (arrows, space,
        // Enter) receive the picker's keys.
        makeFirstResponder(captureHost)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.canDismissOnBlur = true
        }
    }

    /// Dismiss the overlay and hand focus back to the editor. A non-nil `urls`
    /// attaches to the item under the cursor; nil cancels.
    private func closePickerOverEditor(attaching urls: [URL]?) {
        guard pickerOverEditor else { return }
        cancelPickerOverEditor()
        captureHost.alphaValue = 0
        editorContainer.alphaValue = 1
        focusEditor()
        if let urls, !urls.isEmpty { attachToEditorItem(urls) }
    }

    /// Tear the overlay's state down without touching alpha or focus, for the
    /// callers that are already animating both (leaving editor mode) or
    /// rebuilding them wholesale (a fresh summon).
    ///
    /// These flags MUST NOT outlive editor mode: `perform(.attachScreenshot)`
    /// branches on `pickerOverEditor` first, so a stale one sends the next ⌥⌘O
    /// to `closePickerOverEditor` — which fades the capture box to nothing and
    /// moves focus to the hidden web view, instead of opening the picker.
    private func cancelPickerOverEditor() {
        guard pickerOverEditor else { return }
        pickerOverEditor = false
        appState.screenshotPickerItems = nil
        container.pickerOverEditor = false
    }

    /// Attach the chosen screenshots to the item under the cursor.
    ///
    /// The editor is asked whether it *can* take them before a single file is
    /// copied: read mode and a cursor with no item under it both refuse, and a
    /// refusal discovered after the copy would strand the files in the
    /// attachments folder beside the user's capture file with nothing pointing
    /// at them. The editor surfaces the reason itself, next to the rule.
    private func attachToEditorItem(_ urls: [URL]) {
        guard webViewReady else { return }
        webView.evaluateJavaScript(
            "!!(window.qcEditor && window.qcEditor.canAttachToItem && window.qcEditor.canAttachToItem())"
        ) { [weak self] result, _ in
            guard let self, result as? Bool == true else { return }
            self.copyAndInsertAttachments(urls)
        }
    }

    /// Copy the screenshots into the capture file's attachments folder and hand
    /// the editor the child lines. Swift does the copying — the web layer has no
    /// file access beyond the app bundle — and the editor owns where they land.
    private func copyAndInsertAttachments(_ urls: [URL]) {
        var lines: [String] = []
        for url in urls {
            do {
                let relative = try AttachmentStore.copy(url, besideFile: loadedFileURL)
                lines.append(FileWriter.attachmentChildLine(relative))
            } catch {
                NSLog("Attach failed for \(url.lastPathComponent): \(error)")
            }
        }
        guard !lines.isEmpty else {
            editorToast("Couldn't copy those screenshots")
            return
        }
        guard let data = try? JSONEncoder().encode(lines),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.qcEditor && window.qcEditor.attachToItem && window.qcEditor.attachToItem(\(json))",
            completionHandler: nil
        )
    }

    /// Surface a message in the editor's own toast — editor mode has no capture
    /// box to put `attachFeedback` in.
    private func editorToast(_ message: String) {
        guard webViewReady,
              let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.qcEditor && window.qcEditor.toast && window.qcEditor.toast(\(json))",
            completionHandler: nil
        )
    }

    /// Animated centered shrink from the picker frame to a capture box of
    /// `height`. Runs from `captureContentDidChange` once the swapped-back box
    /// has measured; clears `pickerOpen` on completion.
    private func animateCaptureRecenter(toHeight height: CGFloat) {
        guard let screen = currentScreenVisibleFrame() else { pickerOpen = false; return }
        anchorCenterY = screen.midY
        let target = NSRect(x: screen.midX - captureWidth / 2,
                            y: screen.midY - height / 2,
                            width: captureWidth, height: height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.pickerOpen = false
            self.focusCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.canDismissOnBlur = true }
        })
    }

    /// Await the bridge acknowledgement, not just JavaScript dispatch, before
    /// another surface can write the capture file.
    func flushEditorSave(_ completion: @escaping (Bool) -> Void) {
        guard webViewReady else { completion(true); return }
        webView.callAsyncJavaScript("return await window.qcEditor.flushSave()",
                                    arguments: [:], in: nil, in: .page) { [weak self] result in
            switch result {
            case .success(let value): completion((value as? Bool) == true)
            case .failure(let error):
                self?.reportSaveError(error.localizedDescription)
                completion(false)
            }
        }
    }

    private func reportSaveError(_ message: String) {
        guard let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.qcEditor.saveError(\(json))", completionHandler: nil)
    }

    // MARK: - Window overrides

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { editorOpen || workspaceOpen }

    /// Intercept the window-level shortcuts (mode switch, dismiss, screenshot
    /// attach, refile) before CodeMirror/WebKit or the standard menu items can
    /// claim them. Which keys those are — and in which mode — lives in
    /// `ShortcutRegistry`, the single source of truth for bindings.
    private func handleCalendarViewKey(_ event: NSEvent) -> Bool {
        guard workspaceOpen, workspaceModel.destination == .calendar else { return false }
        let textView = firstResponder as? NSTextView
        let editingText = textView?.isEditable == true && textView?.isHiddenOrHasHiddenAncestor == false
        guard let mode = CalendarLayout.mode(for: event.charactersIgnoringModifiers ?? "",
            hasModifiers: !event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
            editingText: editingText) else { return false }
        workspaceModel.calendarMode = mode
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleCalendarViewKey(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleCalendarViewKey(event) { return true }
        // Also handle the summon chord locally while the workspace owns focus.
        // Carbon remains responsible for summoning from other applications.
        if workspaceOpen, UInt32(event.keyCode) == appState.hotKey.keyCode,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == appState.hotKey.modifierFlags {
            show()
            return true
        }
        if workspaceOpen, workspaceModel.destination == .calendar,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "1": workspaceModel.calendarMode = .day; return true
            case "2": workspaceModel.calendarMode = .week; return true
            case "3": workspaceModel.calendarMode = .month; return true
            case "t": workspaceModel.date = Date(); return true
            default: break
            }
            if event.keyCode == 123 { workspaceModel.shiftDate(-1); return true }
            if event.keyCode == 124 { workspaceModel.shiftDate(1); return true }
        }
        if workspaceOpen, event.keyCode == 53 { closeWorkspace(); return true }
        if let action = ShortcutRegistry.interceptedAction(for: event, editorOpen: editorOpen) {
            perform(shortcut: action)
            return true
        }
        // Capture mode has no menu bar, so the standard editing chords
        // (⌘V/⌘C/⌘X/⌘A) have nothing to dispatch them — route them down the
        // responder chain to the focused field. Editor mode keeps its menu bar,
        // so leave those to the standard Edit-menu path.
        if !editorOpen,
           let selector = CaptureEditingChord.selector(
               key: event.charactersIgnoringModifiers?.lowercased(),
               modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)),
           NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Dispatch a shortcut action. Window-intercepted actions call straight
    /// into panel behavior; editor-local actions are driven over the bridge —
    /// the key path for those normally goes through CodeMirror's own keymap,
    /// so this arm only runs for the Editor menu items.
    func perform(shortcut action: ShortcutAction) {
        switch action {
        case .showCalendar: openWorkspace(.calendar)
        case .showProjects: openWorkspace(.projects)
        case .showTodos: openWorkspace(.todos)
        case .showNotes: openWorkspace(.notes)
        case .showLinks: openWorkspace(.links)
        case .toggleEditor:
            toggleEditor()
        case .dismissPanel:
            dismiss()
        case .attachScreenshot:
            if workspaceOpen { closeWorkspace() }
            // ⌥⌘O toggles: a second press while the picker is up closes it the
            // same way Esc does (cancel, attachments untouched).
            if pickerOverEditor {
                closePickerOverEditor(attaching: nil)
            } else if pickerOpen {
                closePickerSurface(attaching: nil)
            } else {
                openScreenshotPicker()
            }
        case .swallowReload:
            // Deliberate no-op: ⌘R must never reach WebKit in editor mode or
            // it reloads the page, destroying the warm editor's state.
            break
        case .refile, .readMode, .toggleTask, .save, .reorg, .archive, .imageSource, .nextSection, .prevSection:
            invokeEditorAction(action)
        }
    }

    /// Run an action inside the editor over the bridge. Refile (⌥⌘U) takes
    /// this path on every press — window-intercepted chords never reach the
    /// web view's keymap, so Swift drives them explicitly.
    private func invokeEditorAction(_ action: ShortcutAction) {
        guard webViewReady,
              let id = String(data: try! JSONEncoder().encode(action.rawValue), encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.qcEditor && window.qcEditor.invoke && window.qcEditor.invoke(\(id))",
            completionHandler: nil
        )
    }

    override func orderOut(_ sender: Any?) {
        canDismissOnBlur = false
        // Capture who holds focus *before* hiding — super.orderOut shifts the
        // frontmost app, after which the third-app guard can't tell our own
        // dismissal apart from a deliberate switch.
        let heldFocus = weHoldFocus
        super.orderOut(sender)
        // Editor mode promoted us to .regular; drop back so we don't linger with
        // a standard menu bar, then hand focus back to where the user came from.
        demoteToAccessory()
        restorePreviousApp(weHeldFocus: heldFocus)
    }

    override func resignKey() {
        super.resignKey()
        guard canDismissOnBlur, !editorOpen, !workspaceOpen, !appState.captureSubmissionActive else { return }
        canDismissOnBlur = false
        dismiss()
    }

    // MARK: - Editor file plumbing

    private func loadEditor() {
        guard let editorHTML = Bundle.main.url(
            forResource: "editor",
            withExtension: "html",
            subdirectory: "dist"
        ) else {
            assertionFailure("editor.html missing from bundle")
            return
        }
        webView.loadFileURL(editorHTML, allowingReadAccessTo: editorHTML.deletingLastPathComponent())
    }

    /// Called by JS once CodeMirror has booted.
    fileprivate func editorDidBecomeReady() {
        webViewReady = true
        // Set vim before content so the first mount() picks up the right mode.
        pushVimSetting()
        pushEditorKeymap()
        pushRefileTargets()
        let text: String
        do {
            text = try FileWriter.read(loadedFileURL, allowingMissing: true)
            editorFileLoaded = true
        } catch {
            // Mount a surface for the persistent error, but refuse writes until
            // this document has actually been read successfully.
            pushContent("")
            reportSaveError("Couldn’t open the file: " + error.localizedDescription)
            startWatching()
            return
        }
        // Unconditional: a fresh web view starts with an empty map, so it needs
        // the push even when nothing was newly allocated.
        appState.assignHues(inContent: text)
        pushTagHues()
        pushContent(text)
        startWatching()
        // The editor no longer auto-focuses on mount; if it was opened before it
        // finished loading (e.g. "Open Editor…" at cold launch), focus it now.
        // Otherwise leave focus with the capture input.
        if editorOpen { focusEditor() }
    }

    /// Push the current vim setting into the editor. Safe before the view
    /// mounts — the JS records the flag and mount() reads it.
    private func pushVimSetting() {
        guard webViewReady else { return }
        webView.evaluateJavaScript(
            "window.qcEditor && window.qcEditor.setVimEnabled(\(appState.vimEnabled))",
            completionHandler: nil
        )
    }

    /// Push the editor-local bindings (`ShortcutRegistry.editorKeymap`) into
    /// the web layer so CodeMirror builds its app keymap from the same source
    /// of truth as the window intercepts. Before this lands the editor runs on
    /// its own baked-in defaults (which the browser harness relies on).
    private func pushEditorKeymap() {
        guard webViewReady, let json = ShortcutRegistry.editorKeymapJSON else { return }
        var hints = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, $0.chord.displayGlyphs) })
        hints["capture"] = appState.hotKey.displayString
        if let data = try? JSONEncoder().encode(hints), let hintJSON = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("window.qcEditor?.setShortcutHints(\(hintJSON))", completionHandler: nil)
        }
        webView.evaluateJavaScript(
            "window.qcEditor && window.qcEditor.setKeymap && window.qcEditor.setKeymap(\(json))",
            completionHandler: nil
        )
    }

    /// One entry of the ⌥⌘U dropdown as the editor sees it: what to show, and
    /// the opaque `id` it hands back so the choice survives the list changing.
    private struct RefileTargetDTO: Encodable {
        let id: String
        let name: String
    }

    /// Push the effective refile targets into the editor so the ⌥⌘U dropdown can
    /// render them. Pushed on editor entry and whenever Settings change the list.
    ///
    /// Each entry carries its target's **path as an id**, and the editor posts
    /// that id back rather than a position. The effective list is filtered by
    /// on-disk existence, which changes with no notification to fire a re-push —
    /// so a folder deleted in Finder used to shift every index below it and land
    /// the item in the wrong inbox. An id can only resolve to the target the
    /// user actually picked, or to nothing.
    private func pushRefileTargets() {
        guard webViewReady else { return }
        let targets = appState.effectiveRefileTargets.map {
            RefileTargetDTO(id: $0.id, name: $0.displayName)
        }
        guard let json = try? JSONEncoder().encode(targets),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.qcEditor && window.qcEditor.setRefileTargets(\(jsonString))",
            completionHandler: nil
        )
    }

    /// Push the resolved section hues into the editor (#102). Sends the light
    /// and dark pair per section name rather than an index, so the editor needs
    /// no copy of `TagPalette` — the hand-synced palette and hash it used to
    /// carry are gone. Keyed by lowercased name, which is how the editor looks
    /// a heading up.
    private func pushTagHues() {
        guard webViewReady else { return }
        var map: [String: [String: String]] = [:]
        for (name, index) in appState.tagHues.indices {
            let entry = TagPalette.entry(at: index)
            map[name] = ["light": entry.lightCSS, "dark": entry.darkCSS]
        }
        guard let json = try? JSONEncoder().encode(map),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.qcEditor && window.qcEditor.setTagHues && window.qcEditor.setTagHues(\(jsonString))",
            completionHandler: nil
        )
    }

    /// Move the editor's subtree at `[fromLine, toLine)` into the chosen refile
    /// target's inbox. The disk surgery lives in `RefileService`; the file
    /// watcher reloads the editor afterwards (same pattern as archive). On
    /// success the editor flashes a toast; on any failure the source is left
    /// intact and an `NSAlert` explains why (the failure contract, R29).
    fileprivate func sendToOrganiser(sourceID: String, fromLine: Int, toLine: Int, subtree: String, asNew: Bool) {
        do {
            let content = try FileWriter.read(loadedFileURL)
            _ = try FileWriter.verifyAndRemove(subtree: subtree, at: fromLine..<toLine, in: content)
            guard SourceIdentity.ids(in: subtree.components(separatedBy: "\n").first ?? "") == [sourceID],
                  SourceIdentity.ids(in: content).filter({ $0 == sourceID }).count == 1 else {
                throw HandoffError.invalid("ambiguous_source_identity")
            }
            HandoffController.shared.send(sourceID: sourceID, body: subtree, sourceFile: loadedFileURL, asNew: asNew)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not send to organiser"
            alert.informativeText = "The source changed or its identity is ambiguous. Save and select the item again."
            alert.runModal()
        }
    }

    fileprivate func refile(targetID: String, fromLine: Int, toLine: Int, subtree: String) {
        do {
            // Resolved by identity, not position: the effective list is
            // recomputed here and may have shrunk since the dropdown was
            // populated. A missing id means the target went away — say so
            // rather than refiling into whatever now sits at that slot.
            guard let target = appState.effectiveRefileTargets.first(where: { $0.id == targetID }) else {
                throw FileWriter.RefileError.targetUnavailable
            }
            try OrganiserController.shared.outbox.prepareMove(ids: SourceIdentity.ids(in: subtree),
                to: target.folderURL.appendingPathComponent("inbox.md"))
            try RefileService.refile(
                subtree: subtree,
                range: fromLine..<toLine,
                from: loadedFileURL,
                toFolder: target.folderURL
            )
            let name = target.displayName
            guard let nameJSON = try? JSONEncoder().encode(name),
                  let nameString = String(data: nameJSON, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.qcEditor && window.qcEditor.refileDidComplete(\(nameString))",
                completionHandler: nil
            )
        } catch {
            OrganiserController.shared.outbox.cancelMove(ids: SourceIdentity.ids(in: subtree))
            let alert = NSAlert()
            alert.messageText = "Couldn’t refile"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Re-point the editor at the current capture file if it changed (path edit
    /// in Settings). When the file is unchanged this is a no-op.
    private func reconcileEditorFile() {
        let url = appState.captureFileURL
        guard url != loadedFileURL, webViewReady else { return }
        flushEditorSave { [weak self] saved in
            guard let self, saved else { return }
            do {
                let text = try FileWriter.read(url, allowingMissing: true)
                self.stopWatching()
                self.loadedFileURL = url
                self.editorFileLoaded = true
                self.pushContent(text)
                self.startWatching()
            } catch { self.reportSaveError("Couldn’t open the file: " + error.localizedDescription) }
        }
    }

    fileprivate func write(_ content: String, expected: String, id: Int) {
        var failure: String?
        var disk: String?
        do {
            guard editorFileLoaded else {
                throw CocoaError(.fileReadUnknown)
            }
            try FileWriter.write(Data(content.utf8), to: loadedFileURL, ifStillMatching: expected)
            lastSyncedContent = content
            appState.assignHues(inContent: content)
        } catch FileWriter.ArchiveError.contentDrifted {
            failure = "The file changed elsewhere. Your unsaved edits are still here. Choose which version to keep."
            disk = try? FileWriter.read(loadedFileURL, allowingMissing: true)
        } catch {
            failure = "Couldn’t save. Your edits are still here. " + error.localizedDescription
        }
        let reply: [String: Any] = ["id": id, "error": failure as Any? ?? NSNull(), "disk": disk as Any? ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: reply),
           let json = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("{ const r = \(json); window.qcEditor.saveResult(r.id, r.error, r.disk); }", completionHandler: nil)
        }
    }

    fileprivate func archive() {
        do {
            try FileWriter.archiveCompleted(at: loadedFileURL)
        } catch FileWriter.ArchiveError.contentDrifted {
            // Archive failures stay NSLog-only by convention, but a drift skip
            // means the user hit the action cluster's archive button and the
            // file simply didn't change — silence there reads as broken. A toast
            // says so without the interruption of an alert.
            NSLog("Editor archive skipped: \(loadedFileURL.path) changed mid-archive")
            editorToast("The file changed while archiving — try again")
        } catch {
            NSLog("Editor archive failed for \(loadedFileURL.path): \(error)")
        }
    }

    /// The editor asked for an attachment's bytes (its file read-access is
    /// scoped to the app bundle, so it can't load capture-folder images
    /// itself). Replies with a data URL — downscaled so a 6K Retina PNG
    /// doesn't ship a multi-MB string over evaluateJavaScript — or null when
    /// the file is missing, which the editor renders as a missing state.
    /// The JS side shows a Loading state while the reply is in flight, so
    /// the async reply is safe.
    fileprivate func sendAttachment(relativePath: String) {
        guard webViewReady else { return }
        let baseDir = loadedFileURL.deletingLastPathComponent().standardizedFileURL
        let resolved = baseDir.appendingPathComponent(relativePath).standardizedFileURL

        // The link is user-editable text — only serve files inside the capture
        // file's folder, so a stray `../../…` path can't read elsewhere.
        guard resolved.path.hasPrefix(baseDir.path + "/") else {
            guard let pathJSON = String(data: try! JSONEncoder().encode(relativePath), encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.qcEditor && window.qcEditor.attachmentLoaded(\(pathJSON), null)",
                completionHandler: nil
            )
            return
        }

        // Thumbnail decode + PNG encode + base64 are CPU/IO-heavy; run them off
        // the main thread so the message-handler callback returns immediately.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var payload = "null"
            if let cg = AttachmentStore.thumbnail(at: resolved, maxPixelSize: 1200),
               let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                payload = "\"data:image/png;base64,\(png.base64EncodedString())\""
            }
            guard let pathJSON = String(data: try! JSONEncoder().encode(relativePath), encoding: .utf8) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.webView.evaluateJavaScript(
                    "window.qcEditor && window.qcEditor.attachmentLoaded(\(pathJSON), \(payload))",
                    completionHandler: nil
                )
            }
        }
    }

    private func pushContent(_ text: String) {
        lastSyncedContent = text
        // The single choke point for editor <- disk, so it covers the initial
        // load, a capture-file switch, and a watcher-driven reload.
        appState.assignHues(inContent: text)
        guard let encoded = String(data: try! JSONEncoder().encode(text), encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.qcEditor.setContent(\(encoded))", completionHandler: nil)
        // Keep the editor's status-bar filename in step with the loaded file.
        if let name = String(data: try! JSONEncoder().encode(loadedFileURL.lastPathComponent), encoding: .utf8) {
            webView.evaluateJavaScript("window.qcEditor.setFilename(\(name))", completionHandler: nil)
        }
    }

    // MARK: - File watching
    //
    // Watch the capture file for external writes (input-only captures, or edits
    // from Obsidian/another app) and reload the editor. Atomic writes replace
    // the file via temp+rename, orphaning our fd, so we re-open on
    // `.rename`/`.delete`.

    private func startWatching() {
        stopWatching()
        let fd = open(loadedFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.handleWatcherEvent() }
        // Capture this watcher's descriptor; a delayed cancellation must not
        // close the replacement watcher's descriptor.
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        fileWatcher = source
    }

    private func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    private func handleWatcherEvent() {
        guard let source = fileWatcher else { return }
        let event = source.data
        if event.contains(.rename) || event.contains(.delete) {
            stopWatching()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.reloadIfChanged()
                self?.startWatching()
            }
            return
        }
        reloadIfChanged()
    }

    private func reloadIfChanged() {
        do {
            let current = try FileWriter.read(loadedFileURL)
            editorFileLoaded = true
            if current == lastSyncedContent { return }
            pushContent(current)
        } catch {
            reportSaveError("Couldn’t reload the file. Your editor content is unchanged. " + error.localizedDescription)
        }
    }
}

// MARK: - Panel container view

/// Hosts both surfaces at once (kept warm) and crossfades between them — the two
/// are mutually-exclusive **modes**, never on screen together (ADR-0004). The
/// editor host always fills the window. The capture host fills the window in
/// **capture mode** (so its SwiftUI content measures correctly and drives the
/// window height) and is pinned to a fixed-size centred box in **editor mode**
/// and during transitions, so it dissolves in place rather than stretching as
/// the frame animates. Plain manual layout — no Auto Layout.
private final class PanelContainerView: NSView {
    private var captureHost: NSView?
    private var editorHost: NSView?

    /// Measured capture-content height; sizes the centred capture box while the
    /// editor is the active surface.
    var captureHeight: CGFloat = 100 { didSet { if editorActive, captureHeight != oldValue { layoutSurfaces() } } }

    /// True while the ⌥⌘O picker is overlaying the editor (#126). The capture
    /// host fills the window as it does in capture mode — CaptureView already
    /// swaps its own content to the picker when items are set — while the
    /// editor stays mounted behind it.
    var pickerOverEditor = false {
        didSet {
            guard pickerOverEditor != oldValue else { return }
            guard let captureHost else { return }
            if pickerOverEditor {
                captureHost.autoresizingMask = [.width, .height]
                captureHost.frame = bounds
            } else if editorActive {
                captureHost.autoresizingMask = []
                layoutSurfaces()
            }
        }
    }

    /// True while the editor is the active surface (and through the open/close
    /// crossfade). Flips the capture host between fill (capture mode) and a
    /// fixed centred box (editor mode / transition).
    var editorActive = false {
        didSet {
            guard editorActive != oldValue else { return }
            if editorActive {
                captureHost?.autoresizingMask = []   // we position it manually
                layoutSurfaces()
            } else {
                // Capture mode: hand the host back to its autoresizing mask so it
                // fills the window. We deliberately do NOT keep managing its frame
                // here — letting the mask size it is what keeps the SwiftUI
                // content measuring correctly so the box grows with its content.
                captureHost?.autoresizingMask = [.width, .height]
                captureHost?.frame = bounds
            }
        }
    }

    private let captureWidth: CGFloat = 680

    func configure(capture: NSView, editor: NSView) {
        self.captureHost = capture
        self.editorHost = editor
        addSubview(editor)    // editor behind…
        addSubview(capture)   // …capture in front
        capture.frame = bounds
        editor.frame = bounds
    }

    // Re-pin while the editor owns the layout. In capture mode the host is sized
    // purely by its autoresizing mask — touching its frame here (during AppKit's
    // layout pass) corrupts the hosting view's intrinsic measurement.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if editorActive, !pickerOverEditor { layoutSurfaces() }
    }

    private func layoutSurfaces() {
        guard let captureHost, let editorHost else { return }
        editorHost.frame = bounds
        // Centred fixed-width box; in capture mode the window equals this size so
        // it reads as full-bleed, and in editor mode it stays put while hidden
        // behind the active surface.
        let h = min(captureHeight, bounds.height)
        captureHost.frame = NSRect(x: (bounds.width - captureWidth) / 2,
                                   y: (bounds.height - h) / 2,
                                   width: captureWidth, height: h)
    }
}

// MARK: - Editor container view

/// Hosts the editor web view full-bleed and is itself the editor's standalone
/// rounded, bordered, steel-surface panel (ADR-0004 — no shared/fused chrome).
private final class EditorContainerView: NSView {
    private var web: NSView?

    // Dynamic so the panel surface/border track light/dark. Layer colours are
    // CGColors (no auto-update), so applyChrome() re-resolves them against the
    // effective appearance, and we re-apply on appearance change.
    // Resolve shared SwiftUI tokens here so native and web window edges agree.
    static let windowSurface = NSColor(name: nil) { a in
        NSColor(a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Theme.dark.surface : Theme.light.surface)
    }
    static let windowBorder = NSColor(name: nil) { a in
        NSColor(a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Theme.dark.border : Theme.light.border)
    }

    func configure(web: NSView) {
        self.web = web
        addSubview(web)
        applyChrome()
        needsLayout = true
    }

    /// Rounded steel panel: corner radius + 1px border + surface fill, all
    /// re-resolved for the current light/dark appearance.
    func applyChrome() {
        wantsLayer = true
        layer?.cornerRadius = Metrics.radiusWindow
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = Self.windowBorder.cgColor
            layer?.backgroundColor = Self.windowSurface.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome()
    }

    override func layout() {
        super.layout()
        web?.frame = bounds
    }
}

// MARK: - JS → Swift bridge

/// WKWebView message handler. JS posts `{ type: "ready" | "save" | "archive" |
/// "dismiss" | "attachment" | "refile", content?: String, path?: String,
/// target?: Int, fromLine?: Int, toLine?: Int, subtree?: String }` to the
/// `editorBridge` handler.
final class EditorBridge: NSObject, WKScriptMessageHandler {
    weak var panel: MainPanel?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            panel?.editorDidBecomeReady()
        case "save":
            if let content = dict["content"] as? String,
               let expected = dict["expected"] as? String,
               let id = dict["id"] as? Int { panel?.write(content, expected: expected, id: id) }
        case "capture":
            panel?.toggleEditor()
        case "screenshots":
            panel?.openScreenshotPicker()
        case "archive":
            panel?.archive()
        case "dismiss":
            // Esc in the editor when vim is off (editor.ts decides).
            panel?.dismissFromEditor()
        case "attachment":
            // The editor wants an image's bytes for the expanded preview.
            if let path = dict["path"] as? String { panel?.sendAttachment(relativePath: path) }
        case "organiserHistory":
            HandoffController.shared.showHistory()
        case "sendOrganiser":
            if let id = dict["sourceID"] as? String,
               let from = dict["fromLine"] as? Int, let to = dict["toLine"] as? Int,
               let subtree = dict["subtree"] as? String {
                panel?.sendToOrganiser(sourceID: id, fromLine: from, toLine: to, subtree: subtree, asNew: dict["asNew"] as? Bool ?? false)
            }
        case "refile":
            // Move the subtree at [fromLine, toLine) into the chosen target.
            if let target = dict["target"] as? String,
               let fromLine = dict["fromLine"] as? Int,
               let toLine = dict["toLine"] as? Int,
               let subtree = dict["subtree"] as? String {
                panel?.refile(targetID: target, fromLine: fromLine, toLine: toLine, subtree: subtree)
            }
        default:
            break
        }
    }
}
