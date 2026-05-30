import AppKit
import Darwin
import SwiftUI
import WebKit

/// The single floating panel that hosts both app surfaces. The capture **input
/// strip** is always pinned to the top; on ⌘F the panel grows downward and the
/// CodeMirror markdown **editor** opens *beneath* it (a "split"), and ⌘F again
/// collapses it away. Both surfaces are stacked at once — they are no longer
/// mutually-exclusive crossfaded modes. See ADR-0003.
///
/// Behaviors keyed to whether the editor is open (`editorOpen`):
/// - **Click-away dismiss** only fires when the editor is closed (`resignKey`);
///   the editor must survive losing focus so you can copy from other apps.
/// - **⌘F** is intercepted in `performKeyEquivalent` *before* it reaches
///   CodeMirror/WebKit (which would treat it as "find"), toggling the editor.
///   **⌘J** jumps focus to the input strip while the editor is open.
/// - **Activation policy** is `.regular` while the editor is open so the
///   standard menu bar (⌘C/V/Z…) works, then `.accessory` when collapsed.
/// - **Single writer:** while the editor is open its in-memory buffer is the
///   canonical copy of the file; a capture is inserted into the buffer (reusing
///   `FileWriter.insert` + a targeted CodeMirror transaction) rather than
///   written to disk directly. Closed → captures write the file as before.
final class MainPanel: NSPanel {
    private let appState: AppState
    private let onSubmit: (String, String?) -> Void
    private let onDismiss: () -> Void

    private(set) var editorOpen = false

    // MARK: Surfaces

    private let split = SplitContainerView()
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

    private let splitWidth: CGFloat = 1000
    private let captureWidth: CGFloat = 600

    deinit { stopWatching() }

    init(appState: AppState,
         onSubmit: @escaping (String, String?) -> Void,
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
        appearance = NSAppearance(named: .aqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        setupContainer()
        bridge.panel = self
        config.userContentController.add(bridge, name: "editorBridge")
        loadEditor()
    }

    private func setupContainer() {
        // Start surfaces at the real capture size so AppKit's first
        // resize-to-content-rect (on `contentView = split`) is a no-op rather
        // than a degenerate scale-up from `.zero`.
        let initialFrame = NSRect(x: 0, y: 0, width: captureWidth, height: 100)
        split.frame = initialFrame
        split.stripHeight = captureContentSize.height

        captureHost = NSHostingView(rootView: makeCaptureView())
        captureHost.wantsLayer = true
        captureHost.frame = initialFrame
        // Autoresizing keeps the input strip filling the window as it grows with
        // multi-line input / tag suggestions (the proven capture behavior).
        // `SplitContainerView.relayout` overrides this only while the editor is
        // open, to pin the strip to the top.
        captureHost.autoresizingMask = [.width, .height]

        editorContainer.wantsLayer = true
        editorContainer.layer?.cornerRadius = 12
        editorContainer.layer?.masksToBounds = true
        editorContainer.layer?.backgroundColor = NSColor.white.cgColor
        editorContainer.layer?.borderWidth = 1
        editorContainer.layer?.borderColor = NSColor.black.withAlphaComponent(0.07).cgColor
        editorContainer.frame = initialFrame
        editorContainer.autoresizingMask = [.width, .height]
        editorContainer.isHidden = true
        editorContainer.alphaValue = 0

        webView.setValue(false, forKey: "drawsBackground")   // no white flash on load
        editorContainer.configure(web: webView)

        split.configure(inputStrip: captureHost, editorHost: editorContainer)
        contentView = split
    }

    /// Rebuilds the capture surface for the current `editorOpen`/filename. @State
    /// (typed text, focus) survives because NSHostingView preserves the SwiftUI
    /// graph across rootView updates of the same view type.
    private func makeCaptureView() -> CaptureView {
        CaptureView(
            appState: appState,
            onSubmit: { [weak self] text, tag in self?.handleSubmit(text, tag) },
            onClose: { [weak self] in self?.onDismiss() },
            onToggleEditor: { [weak self] in self?.toggleEditor() },
            onEscape: { [weak self] in self?.handleEscape() },
            onContentSizeChange: { [weak self] size in self?.captureContentDidChange(size) },
            editorOpen: editorOpen,
            filename: loadedFileURL.lastPathComponent
        )
    }

    private func refreshCaptureView() {
        captureHost.rootView = makeCaptureView()
    }

    // MARK: - Presentation

    /// Summon input-only. Always resets so re-summoning after a dismiss lands on
    /// the capture box.
    func show() {
        collapseStateReset()
        if let screen = currentScreenVisibleFrame() {
            anchorCenterY = screen.midY
            var f = frame
            f.size.width = captureWidth
            setFrame(f, display: false)
            // Force layout so frame.height reflects real content size before we
            // position — otherwise the first show jumps after the size report.
            split.layoutSubtreeIfNeeded()
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
        editorOpen = true
        refreshCaptureView()
        isMovableByWindowBackground = false
        promoteToRegular()
        reconcileEditorFile()
        split.editorVisible = true
        editorContainer.isHidden = false
        editorContainer.alphaValue = 1
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
    }

    // MARK: - Open / close

    func toggleEditor() {
        editorOpen ? closeEditor() : openEditor()
    }

    /// Grow into the split: comfortable width, full visible height, centered.
    func openEditor() {
        guard !editorOpen else { return }
        editorOpen = true
        refreshCaptureView()
        isMovableByWindowBackground = false
        promoteToRegular()
        NSApp.activate(ignoringOtherApps: true)
        reconcileEditorFile()

        split.editorVisible = true
        editorContainer.isHidden = false
        editorContainer.alphaValue = 0

        guard let screen = currentScreenVisibleFrame() else { return }
        let target = splitFrame(in: screen)
        anchorCenterY = target.midY
        animateFrame(to: target, fadeEditorTo: 1) { [weak self] in
            self?.focusEditor()
        }
    }

    /// Collapse back to the input box, re-centered on screen.
    func closeEditor() {
        guard editorOpen else { return }
        editorOpen = false
        refreshCaptureView()
        isMovableByWindowBackground = true

        guard let screen = currentScreenVisibleFrame() else { return }
        anchorCenterY = screen.midY
        let target = NSRect(x: screen.midX - captureWidth / 2,
                            y: screen.midY - split.stripHeight / 2,
                            width: captureWidth, height: split.stripHeight)
        animateFrame(to: target, fadeEditorTo: 0) { [weak self] in
            guard let self else { return }
            self.split.editorVisible = false
            self.editorContainer.isHidden = true
            // The web view held first responder under `.regular`; drop back to
            // `.accessory` and re-establish key/active before focusing, else
            // `makeFirstResponder` lands on a non-key panel and the field gets
            // no editing focus.
            self.demoteToAccessory()
            NSApp.activate(ignoringOtherApps: true)
            self.makeKeyAndOrderFront(nil)
            self.orderFrontRegardless()
            self.focusCapture()
            self.canDismissOnBlur = true
        }
    }

    /// Animate the window frame while fading the editor in/out. The input strip
    /// never fades — it stays put as the panel grows around it.
    private func animateFrame(to targetFrame: NSRect,
                              fadeEditorTo alpha: CGFloat,
                              completion: @escaping () -> Void) {
        canDismissOnBlur = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(targetFrame, display: true)
            editorContainer.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    private func collapseStateReset() {
        // Only rebuild the capture view if we're actually coming back from the
        // editor (header differs). Reassigning the hosting view's rootView on a
        // plain re-summon resets SwiftUI's size measurement to zero before the
        // window lays out, so the box never grows to fit the tag suggestions.
        let wasOpen = editorOpen
        editorOpen = false
        if wasOpen { refreshCaptureView() }
        split.editorVisible = false
        editorContainer.isHidden = true
        editorContainer.alphaValue = 0
        isMovableByWindowBackground = true
        demoteToAccessory()
    }

    // MARK: - Frames

    private func currentScreenVisibleFrame() -> NSRect? {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? self.screen ?? NSScreen.main
        return screen?.visibleFrame
    }

    /// Input-only: resize the window to the capture content height (anchored to
    /// `anchorCenterY`). Split: the window keeps its full-height editor frame;
    /// only the internal split line moves, so typing a multi-line capture
    /// doesn't resize the editor window.
    private func captureContentDidChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        captureContentSize = size
        split.stripHeight = size.height
        guard !editorOpen else {
            split.needsLayout = true
            return
        }
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

    // MARK: - Focus

    private func focusCapture() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let tv = self.firstTextView(in: self.captureHost) else { return }
            self.makeFirstResponder(tv)
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

    /// Esc: return focus to the editor when it's open, otherwise dismiss.
    private func handleEscape() {
        if editorOpen { focusEditor() } else { onDismiss() }
    }

    /// A capture submitted from the input strip. When the editor is closed (or
    /// the capture is a `#cal` event, which never writes a todo) it takes the
    /// unchanged disk path. When the editor is open it routes through the live
    /// buffer so there's only ever one writer to the file.
    private func handleSubmit(_ text: String, _ tag: String?) {
        let isCal = tag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cal"
        if !editorOpen || isCal {
            onSubmit(text, tag)
            return
        }
        insertIntoEditorBuffer(text, tag: tag)
    }

    /// Reuse the pure `FileWriter.insert` over the editor's current buffer, then
    /// apply just the delta as a targeted transaction (cursor/scroll/undo
    /// preserved). Focus is in the input here, so the buffer is stable across
    /// the async round-trip.
    private func insertIntoEditorBuffer(_ text: String, tag: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let heading = FileWriter.sectionName(for: tag)
        let item = FileWriter.todoLine(trimmed, includeTimestamp: appState.includeTimestamp)

        webView.evaluateJavaScript("window.qcEditor.getContent()") { [weak self] result, _ in
            guard let self, let old = result as? String else { return }
            let new = FileWriter.insert(item: item, underHeading: heading, in: old)
            guard let (from, inserted) = Self.singleInsertionDelta(from: old, to: new) else {
                // Non-contiguous change (e.g. a missing `# Inbox` got prepended
                // *and* the item inserted). Rare; fall back to a full replace.
                NSLog("Capture insert produced a non-contiguous delta; full replace.")
                self.pushContent(new)
                self.focusEditor()
                return
            }
            guard let payload = String(data: try! JSONEncoder().encode(inserted), encoding: .utf8) else { return }
            self.webView.evaluateJavaScript("window.qcEditor.insertCapture(\(from), \(payload))",
                                            completionHandler: nil)
            self.focusEditor()
        }
    }

    /// `old` and `new` differ by exactly one inserted run (`FileWriter.insert`
    /// only adds). Returns the UTF-16 offset (CodeMirror indexing) and the
    /// inserted text, or nil if the change isn't a single contiguous insertion.
    static func singleInsertionDelta(from old: String, to new: String) -> (Int, String)? {
        let o = Array(old.utf16), n = Array(new.utf16)
        guard n.count > o.count else { return nil }
        var p = 0
        while p < o.count && o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p && o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        // What remains in `old` after stripping the shared prefix/suffix must be
        // empty for this to be a pure insertion.
        guard p + s == o.count else { return nil }
        let units = Array(n[p ..< n.count - s])
        return (p, String(utf16CodeUnits: units, count: units.count))
    }

    // MARK: - Window overrides

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { editorOpen }

    /// Intercept ⌘F (toggle editor) and ⌘J (focus the input strip) before
    /// CodeMirror/WebKit can claim them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            toggleEditor()
            return true
        case "j" where editorOpen:
            focusCapture()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func orderOut(_ sender: Any?) {
        canDismissOnBlur = false
        super.orderOut(sender)
    }

    override func resignKey() {
        super.resignKey()
        guard !editorOpen, canDismissOnBlur else { return }
        canDismissOnBlur = false
        onDismiss()
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
        let text = (try? String(contentsOf: loadedFileURL, encoding: .utf8)) ?? ""
        pushContent(text)
        startWatching()
    }

    /// Re-point the editor at the current capture file if it changed (path edit
    /// in Settings). When the file is unchanged this is a no-op.
    private func reconcileEditorFile() {
        let url = appState.captureFileURL
        guard url != loadedFileURL else { return }
        loadedFileURL = url
        refreshCaptureView()
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

    private func pushContent(_ text: String) {
        lastSyncedContent = text
        guard let encoded = String(data: try! JSONEncoder().encode(text), encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.qcEditor.setContent(\(encoded))", completionHandler: nil)
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

// MARK: - Split container view

/// Stacks the capture input strip (pinned to the top) above the editor host.
/// Input-only: the strip fills the whole view, the editor is hidden. Split: the
/// strip takes `stripHeight` at the top and the editor fills the rest below a
/// small gap. Plain manual layout — no Auto Layout — to match the rest.
private final class SplitContainerView: NSView {
    private var inputStrip: NSView?
    private var editorHost: NSView?

    var stripHeight: CGFloat = 100 { didSet { if editorVisible, stripHeight != oldValue { relayoutSplit() } } }
    var editorVisible = false {
        didSet {
            guard editorVisible != oldValue else { return }
            if editorVisible {
                relayoutSplit()
            } else {
                // Back to input-only: hand the strip back to autoresizing and
                // hide the editor. We deliberately do NOT keep managing the
                // strip's frame in input-only — letting the autoresizing mask
                // size it (like the original plain container) is what keeps the
                // SwiftUI content measuring correctly so the box grows to fit.
                inputStrip?.frame = bounds
                editorHost?.isHidden = true
            }
        }
    }
    private let gap: CGFloat = 10

    func configure(inputStrip: NSView, editorHost: NSView) {
        self.inputStrip = inputStrip
        self.editorHost = editorHost
        addSubview(editorHost)
        addSubview(inputStrip)
        inputStrip.frame = bounds
        editorHost.isHidden = true
    }

    // Only re-pin the split surfaces while the editor is open. In input-only the
    // capture host is sized purely by its autoresizing mask — touching its frame
    // here (during AppKit's layout pass) corrupts the hosting view's intrinsic
    // measurement and the box stops growing with its content.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if editorVisible { relayoutSplit() }
    }

    private func relayoutSplit() {
        guard let inputStrip, let editorHost else { return }
        inputStrip.frame = NSRect(x: 0, y: bounds.height - stripHeight,
                                  width: bounds.width, height: stripHeight)
        let editorH = max(0, bounds.height - stripHeight - gap)
        editorHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: editorH)
        editorHost.isHidden = false
    }
}

// MARK: - Editor container view

/// Hosts the editor web view, full bounds. The filename/close chrome now lives
/// in the capture input strip's header (see CaptureView), so there's no
/// separate chrome bar.
private final class EditorContainerView: NSView {
    private var web: NSView?

    func configure(web: NSView) {
        self.web = web
        addSubview(web)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        web?.frame = bounds
    }
}

// MARK: - JS → Swift bridge

/// WKWebView message handler. JS posts `{ type: "ready" | "save" | "archive",
/// content?: String }` to the `editorBridge` handler.
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
        default:
            break
        }
    }
}
