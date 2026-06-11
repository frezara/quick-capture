import AppKit
import Darwin
import SwiftUI
import WebKit

/// The single floating panel that hosts both app surfaces — the capture box and
/// the CodeMirror markdown editor — as **mutually-exclusive modes** (ADR-0004).
/// Both stay mounted (the editor's web view is kept warm); ⌘F crossfades
/// between them while animating the window frame, so exactly one is visible.
///
/// Behaviors keyed to whether the editor is open (`editorOpen`):
/// - **Click-away dismiss** only fires in capture mode (`resignKey`); the
///   editor survives losing focus so you can copy from other apps.
///   `canDismissOnBlur` guards against false fires during transitions.
/// - **⌘F** is intercepted in `performKeyEquivalent` *before* it reaches
///   CodeMirror/WebKit (which would treat it as "find"), toggling the mode.
/// - **Activation policy** is `.regular` while the editor is open so the
///   standard menu bar (⌘C/V/Z…) works, then `.accessory` when collapsed.
/// - **Disk is canonical, one writer by mutual exclusion:** capture-mode
///   submits write straight to disk via `FileWriter`; the editor flushes its
///   debounced save (`flushEditorSave`) before leaving editor mode, and the
///   file watcher reloads the warm editor on external changes.
final class MainPanel: NSPanel {
    private let appState: AppState
    private let onSubmit: (String, String?, URL?) -> Bool
    private let onDismiss: () -> Void

    private(set) var editorOpen = false
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
    private var webViewReady = false
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var vimObserver: NSObjectProtocol?
    private var refileTargetsObserver: NSObjectProtocol?
    /// True for the duration of the editor→capture collapse animation, so
    /// `captureContentDidChange` defers window geometry to the animation.
    private var isCollapsing = false
    /// Incremented on every fresh summon or ⌘⇧S; completion blocks capture it
    /// so stale completions from a prior summon cannot resurrect a detached chip.
    private var attachLookupGeneration = 0

    private let splitWidth: CGFloat = 1000
    private let captureWidth: CGFloat = 600

    deinit {
        stopWatching()
        if let vimObserver { NotificationCenter.default.removeObserver(vimObserver) }
        if let refileTargetsObserver { NotificationCenter.default.removeObserver(refileTargetsObserver) }
    }

    init(appState: AppState,
         onSubmit: @escaping (String, String?, URL?) -> Bool,
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

        // Live-toggle vim in the editor when the setting changes.
        vimObserver = NotificationCenter.default.addObserver(
            forName: .vimModeDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.pushVimSetting() }

        // Refile targets edited in Settings take effect in the editor's ⌘R
        // dropdown without a restart (R35) — the editor can't read settings, so
        // we re-push the effective list whenever it changes.
        refileTargetsObserver = NotificationCenter.default.addObserver(
            forName: .refileTargetsDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.pushRefileTargets() }
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
            onSubmit: { [weak self] text, tag, attachment in self?.onSubmit(text, tag, attachment) ?? false },
            onClose: { [weak self] in self?.onDismiss() },
            onToggleEditor: { [weak self] in self?.toggleEditor() },
            onEscape: { [weak self] in self?.handleEscape() },
            onContentSizeChange: { [weak self] size in self?.captureContentDidChange(size) },
            onPickerAttach: { [weak self] url in self?.closePickerSurface(attaching: url) },
            onPickerCancel: { [weak self] in self?.closePickerSurface(attaching: nil) }
        )
    }

    // MARK: - Presentation

    /// Summon input-only. Always resets so re-summoning after a dismiss lands on
    /// the capture box.
    func show() {
        recordPreviousApp()   // before NSApp.activate steals frontmost from it
        collapseStateReset()
        detectRecentScreenshot()
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

    /// Editor-mode frame: comfortable fixed width, full visible height (clears
    /// the menu bar and Dock), centered horizontally on the active screen.
    private func splitFrame(in screen: NSRect) -> NSRect {
        NSRect(x: screen.midX - splitWidth / 2,
               y: screen.minY,
               width: splitWidth,
               height: screen.height)
    }

    /// Summon straight into the split (the menu-bar "Open Editor…" route),
    /// without the grow animation.
    func showInEditor() {
        recordPreviousApp()   // before promote/activate steals frontmost from it
        editorOpen = true
        isMovableByWindowBackground = false
        promoteToRegular()
        reconcileEditorFile()
        container.editorActive = true
        editorContainer.isHidden = false
        editorContainer.alphaValue = 1
        captureHost.alphaValue = 0
        if let screen = currentScreenVisibleFrame() {
            let target = splitFrame(in: screen)
            anchorCenterY = target.midY
            setFrame(target, display: false)
        }
        canDismissOnBlur = false
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        focusEditor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.canDismissOnBlur = true
        }
    }

    // MARK: - Open / close

    func toggleEditor() {
        editorOpen ? closeEditor() : openEditor()
    }

    /// Switch to editor mode: crossfade the capture box out and the full editor
    /// in while the window grows to the editor frame.
    func openEditor() {
        guard !editorOpen else { return }
        editorOpen = true
        // The picker is a capture-surface affordance; ⌘F into the editor closes
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
        guard editorOpen else { return }
        flushEditorSave()   // disk canonical before capture mode can write (ADR-0004)
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
        // The picker takeover fills the window with a fixed centered frame.
        // Ignore its size entirely — recording it would clobber the saved
        // capture height that closePickerSurface uses to restore the box.
        guard !pickerOpen else { return }
        captureContentSize = size
        container.captureHeight = size.height
        guard !editorOpen else { return }
        // While collapsing editor→capture, the frame animation owns the window
        // geometry. Without this, the re-measure that closeEditor triggers (it
        // sets editorOpen=false, so we'd reach here) fires a non-animated
        // setFrame to a box at the editor's edge — which then animates to centre,
        // reading as "shrink to the side, then re-centre". Record the size for
        // the animation target; let the animation place the frame.
        guard !isCollapsing else { return }
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
        previousApp = (front?.processIdentifier == myPID) ? nil : front
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
            guard let self else { return }
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
    private func dismiss() {
        flushEditorSave()
        onDismiss()
    }

    /// Esc in the editor with vim off (posted from editor.ts via the bridge).
    fileprivate func dismissFromEditor() { dismiss() }

    // MARK: - Screenshot attach

    /// Detection runs only on a fresh summon (R20) — never on the ⌘F return —
    /// so a detached chip stays detached for the rest of the capture session.
    private func detectRecentScreenshot() {
        attachLookupGeneration += 1
        let generation = attachLookupGeneration
        appState.pendingAttachment = nil
        appState.recentScreenshotExists = false
        appState.attachFeedback = nil
        appState.screenshotPickerItems = nil
        let window = appState.screenshotAttachWindow
        ScreenshotLocator.mostRecent { [weak self] shot in
            guard let self, generation == self.attachLookupGeneration, let shot else { return }
            let age = Date().timeIntervalSince(shot.createdAt)
            if window < 0 || age <= window {
                self.appState.pendingAttachment = shot.url
            } else {
                self.appState.recentScreenshotExists = true
            }
        }
    }

    /// ⌘⇧S — open the screenshot picker takeover surface with the 10 most
    /// recent screenshots (newest pre-highlighted). Picking one attaches it as
    /// the chip; Esc closes without changing the attachment. No screenshots →
    /// the transient "No screenshots found" feedback instead of an empty panel.
    private func openScreenshotPicker() {
        attachLookupGeneration += 1
        let generation = attachLookupGeneration
        ScreenshotLocator.recent(limit: 10) { [weak self] shots in
            guard let self, generation == self.attachLookupGeneration, !self.editorOpen else { return }
            if shots.isEmpty {
                self.appState.screenshotPickerItems = nil
                self.appState.attachFeedback = "No screenshots found"
            } else {
                self.appState.screenshotPickerItems = shots
                self.enterPickerSurface()
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

    /// Close the picker surface, optionally attaching `url` as the chip, and
    /// shrink back to the centered capture box. `pickerOpen` stays true until the
    /// shrink finishes so the capture re-measure (CaptureView swaps back the
    /// moment items clear) can't fire a competing non-animated setFrame.
    private func closePickerSurface(attaching url: URL?) {
        if let url { appState.pendingAttachment = url }
        appState.screenshotPickerItems = nil
        guard pickerOpen, let screen = currentScreenVisibleFrame() else { pickerOpen = false; return }
        canDismissOnBlur = false
        anchorCenterY = screen.midY
        let target = NSRect(x: screen.midX - captureWidth / 2,
                            y: screen.midY - captureContentSize.height / 2,
                            width: captureWidth, height: captureContentSize.height)
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

    /// Flush the editor's debounced autosave so disk is current before leaving
    /// editor mode (no-op until the editor has loaded). The call is async, but
    /// the web view is never torn down, so the queued save still lands.
    private func flushEditorSave() {
        guard webViewReady else { return }
        webView.evaluateJavaScript("window.qcEditor && window.qcEditor.flushSave && window.qcEditor.flushSave()",
                                   completionHandler: nil)
    }

    // MARK: - Window overrides

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { editorOpen }

    /// Intercept ⌘F (switch mode), ⌘W (dismiss), and ⌘⇧S (attach screenshot)
    /// before CodeMirror/WebKit or the standard menu items can claim them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        // ⌘⇧S carries [.command, .shift], so it must be matched before the
        // exact-Command guard below would bounce it to super. Capture mode
        // only — the chip is a capture-surface affordance.
        if mods == [.command, .shift], key == "s", !editorOpen {
            openScreenshotPicker()
            return true
        }

        guard mods == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "f":
            toggleEditor()
            return true
        case "w":
            dismiss()
            return true
        case "r" where editorOpen:
            // ⌘R must be caught here: WebKit reserves it for "reload" and would
            // swallow it before CodeMirror's Mod-r keymap ever runs (same reason
            // ⌘F is intercepted above). Drive the editor's refile over the bridge.
            webView.evaluateJavaScript(
                "window.qcEditor && window.qcEditor.startRefile()",
                completionHandler: nil
            )
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
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
        guard canDismissOnBlur else { return }
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
        pushRefileTargets()
        let text = (try? String(contentsOf: loadedFileURL, encoding: .utf8)) ?? ""
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

    /// Push the effective refile targets (display names) into the editor so the
    /// ⌘R dropdown can render them. The editor refers to a target by its index
    /// in this list when it posts a `refile` message. Pushed on editor entry and
    /// whenever Settings change the list.
    private func pushRefileTargets() {
        guard webViewReady else { return }
        let names = appState.effectiveRefileTargets.map(\.displayName)
        guard let json = try? JSONEncoder().encode(names),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.qcEditor && window.qcEditor.setRefileTargets(\(jsonString))",
            completionHandler: nil
        )
    }

    /// Move the editor's subtree at `[fromLine, toLine)` into the chosen refile
    /// target's inbox. The disk surgery lives in `RefileService`; the file
    /// watcher reloads the editor afterwards (same pattern as archive). On
    /// success the editor flashes a toast; on any failure the source is left
    /// intact and an `NSAlert` explains why (the failure contract, R29).
    fileprivate func refile(targetIndex: Int, fromLine: Int, toLine: Int, subtree: String) {
        let targets = appState.effectiveRefileTargets
        guard targets.indices.contains(targetIndex) else { return }
        let target = targets[targetIndex]
        do {
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
        guard url != loadedFileURL else { return }
        loadedFileURL = url
        guard webViewReady else { return }
        stopWatching()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        pushContent(text)
        startWatching()
    }

    fileprivate func write(_ content: String) {
        do {
            try content.write(to: loadedFileURL, atomically: true, encoding: .utf8)
            lastSyncedContent = content
        } catch {
            NSLog("Editor failed to write \(loadedFileURL.path): \(error)")
        }
    }

    fileprivate func archive() {
        do {
            try FileWriter.archiveCompleted(at: loadedFileURL)
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
        fileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.handleWatcherEvent() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                Darwin.close(fd)
                self?.fileDescriptor = -1
            }
        }
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
        let current = (try? String(contentsOf: loadedFileURL, encoding: .utf8)) ?? ""
        if current == lastSyncedContent { return }
        pushContent(current)
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

    private let captureWidth: CGFloat = 600

    func configure(capture: NSView, editor: NSView) {
        self.captureHost = capture
        self.editorHost = editor
        addSubview(editor)    // editor behind…
        addSubview(capture)   // …capture in front (crossfade decides what shows)
        capture.frame = bounds
        editor.frame = bounds
    }

    // Only re-pin while the editor is active. In capture mode the host is sized
    // purely by its autoresizing mask — touching its frame here (during AppKit's
    // layout pass) corrupts the hosting view's intrinsic measurement.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if editorActive { layoutSurfaces() }
    }

    private func layoutSurfaces() {
        guard let captureHost, let editorHost else { return }
        editorHost.frame = bounds
        // Centred fixed-width box; in capture mode the window equals this size so
        // it reads as full-bleed, and in editor mode it stays put while hidden.
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
    // Mirrors Theme.surface / Theme.borderStrong (design/native-v2/HANDOFF.md).
    static let windowSurface = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x21/255, green: 0x21/255, blue: 0x25/255, alpha: 1)
            : NSColor(srgbRed: 0xF6/255, green: 0xF6/255, blue: 0xF8/255, alpha: 1)
    }
    static let windowBorder = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(white: 0, alpha: 0.18)
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
            if let content = dict["content"] as? String { panel?.write(content) }
        case "archive":
            panel?.archive()
        case "dismiss":
            // Esc in the editor when vim is off (editor.ts decides).
            panel?.dismissFromEditor()
        case "attachment":
            // The editor wants an image's bytes for the expanded preview.
            if let path = dict["path"] as? String { panel?.sendAttachment(relativePath: path) }
        case "refile":
            // Move the subtree at [fromLine, toLine) into the chosen target.
            if let target = dict["target"] as? Int,
               let fromLine = dict["fromLine"] as? Int,
               let toLine = dict["toLine"] as? Int,
               let subtree = dict["subtree"] as? String {
                panel?.refile(targetIndex: target, fromLine: fromLine, toLine: toLine, subtree: subtree)
            }
        default:
            break
        }
    }
}
