import AppKit
import Darwin
import SwiftUI
import WebKit

/// The single floating panel that hosts both app surfaces. It starts life as
/// the small capture box and, on ⌘F, grows in place into the CodeMirror
/// markdown editor (and shrinks back). Both surfaces live in the same window
/// at once — only their visibility/opacity and the window frame change — so
/// the transition is a crossfade + frame animation rather than a window swap.
///
/// Mode-dependent behaviors:
/// - **Click-away dismiss** only fires in `.capture` (see `resignKey`); the
///   editor must survive losing focus so you can copy from other apps.
/// - **⌘F** is intercepted in `performKeyEquivalent` *before* it reaches
///   CodeMirror/WebKit (which would treat it as "find"), toggling the mode.
/// - **Activation policy** is bumped to `.regular` only while editing so the
///   standard menu bar (⌘C/V/Z…) is available, then dropped back to
///   `.accessory` so the dock icon disappears — same as the old editor window.
final class MainPanel: NSPanel {
    enum Mode { case capture, editor }

    private let appState: AppState
    private let onSubmit: (String, String?) -> Void
    private let onDismiss: () -> Void

    private(set) var mode: Mode = .capture

    // MARK: Surfaces

    private let container = NSView()
    private var captureHost: NSHostingView<CaptureView>!
    private let editorContainer = EditorContainerView()
    private let webView: WKWebView
    private let bridge = EditorBridge()

    // MARK: Capture sizing

    /// Screen-coordinate Y of the desired panel center, captured at show time.
    /// All capture-mode resizes anchor to this so the box stays centered as it
    /// grows with multi-line input (see the long note in the original panel).
    private var anchorCenterY: CGFloat = 0
    /// Latest intrinsic size reported by `CaptureView`. Tracked in every mode
    /// (so a shrink-back has a target height) but only applied to the frame
    /// while in `.capture`.
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

    private let editorWidth: CGFloat = 900
    private let editorHeight: CGFloat = 700
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
        // Give the container and both surfaces a correct non-zero frame *before*
        // `contentView = container` triggers AppKit's resize-to-content-rect.
        // Autoresizing scales subviews by the superview's frame delta, and
        // scaling up from a `.zero` frame is degenerate — it leaves captureHost
        // mis-sized, which breaks the content-driven panel growth (tag focus /
        // multi-line input). Starting them at the real size makes that first
        // resize a no-op.
        let initialFrame = NSRect(x: 0, y: 0, width: captureWidth, height: 100)
        container.frame = initialFrame
        container.autoresizingMask = [.width, .height]

        let capture = CaptureView(
            appState: appState,
            onSubmit: { [weak self] text, tag in self?.onSubmit(text, tag) },
            onDismiss: { [weak self] in self?.onDismiss() },
            onOpenEditor: { [weak self] in self?.switchToEditor() },
            onContentSizeChange: { [weak self] size in self?.captureContentDidChange(size) }
        )
        captureHost = NSHostingView(rootView: capture)
        captureHost.wantsLayer = true
        captureHost.frame = initialFrame
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

        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")   // no white flash on load

        let chrome = NSHostingView(rootView: editorChromeBar(title: loadedFileURL.lastPathComponent))
        editorContainer.configure(chrome: chrome, web: webView)

        container.addSubview(captureHost)
        container.addSubview(editorContainer)
        contentView = container
    }

    private func editorChromeBar(title: String) -> EditorChromeBar {
        EditorChromeBar(
            title: title,
            onBack: { [weak self] in self?.switchToCapture() },
            onClose: { [weak self] in self?.onDismiss() }
        )
    }

    // MARK: - Presentation

    /// Summon in capture mode. Always resets to capture so re-summoning after a
    /// dismiss (from either mode) lands on the capture box.
    func show() {
        resetToCaptureMode()
        if let screenFrame = currentScreenVisibleFrame() {
            anchorCenterY = screenFrame.midY
            var f = frame
            f.size.width = captureWidth
            setFrame(f, display: false)
            // Force layout so frame.height reflects the real content size before
            // we position — otherwise the first show jumps after the initial
            // content-size report.
            container.layoutSubtreeIfNeeded()
            let x = screenFrame.midX - captureWidth / 2
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

    /// Summon directly into the editor (the menu-bar "Open Editor…" route).
    /// Jumps to the editor frame without the grow animation.
    func showInEditor() {
        mode = .editor
        captureHost.isHidden = true
        captureHost.alphaValue = 0
        editorContainer.isHidden = false
        editorContainer.alphaValue = 1
        isMovableByWindowBackground = false
        promoteToRegular()
        reconcileEditorFile()
        if let screenFrame = currentScreenVisibleFrame() {
            setFrame(editorFrame(in: screenFrame), display: false)
        }
        canDismissOnBlur = false
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        focusEditor()
    }

    // MARK: - Mode switching

    func toggleMode() {
        switch mode {
        case .capture: switchToEditor()
        case .editor:  switchToCapture()
        }
    }

    func switchToEditor() {
        guard mode == .capture else { return }
        mode = .editor
        isMovableByWindowBackground = false
        promoteToRegular()
        NSApp.activate(ignoringOtherApps: true)
        reconcileEditorFile()
        guard let screenFrame = currentScreenVisibleFrame() else { return }
        animateTransition(to: editorFrame(in: screenFrame), showingEditor: true) { [weak self] in
            self?.focusEditor()
        }
    }

    func switchToCapture() {
        guard mode == .editor else { return }
        mode = .capture
        isMovableByWindowBackground = true
        guard let screenFrame = currentScreenVisibleFrame() else { return }
        anchorCenterY = screenFrame.midY
        animateTransition(to: captureFrame(in: screenFrame), showingEditor: false) { [weak self] in
            guard let self else { return }
            // The web view held first-responder under a `.regular` policy; drop
            // back to `.accessory` and re-establish the panel as key/active
            // before focusing — otherwise `makeFirstResponder` lands on a panel
            // that isn't key and the todo field gets no editing focus.
            self.demoteToAccessory()
            NSApp.activate(ignoringOtherApps: true)
            self.makeKeyAndOrderFront(nil)
            self.orderFrontRegardless()
            self.focusCapture()
            self.canDismissOnBlur = true
        }
    }

    /// Crossfades the two surfaces while animating the window frame so the box
    /// appears to grow into / shrink out of the editor.
    private func animateTransition(to targetFrame: NSRect,
                                   showingEditor: Bool,
                                   completion: @escaping () -> Void) {
        // Reveal the incoming surface (at alpha 0) before animating in.
        if showingEditor {
            editorContainer.isHidden = false
        } else {
            captureHost.isHidden = false
        }
        canDismissOnBlur = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(targetFrame, display: true)
            captureHost.animator().alphaValue = showingEditor ? 0 : 1
            editorContainer.animator().alphaValue = showingEditor ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Hide the outgoing surface so it can't intercept clicks/focus.
            if showingEditor {
                self.captureHost.isHidden = true
            } else {
                self.editorContainer.isHidden = true
            }
            completion()
        })
    }

    private func resetToCaptureMode() {
        mode = .capture
        captureHost.isHidden = false
        captureHost.alphaValue = 1
        editorContainer.isHidden = true
        editorContainer.alphaValue = 0
        isMovableByWindowBackground = true
        demoteToAccessory()
    }

    // MARK: - Frames

    private func editorFrame(in screen: NSRect) -> NSRect {
        NSRect(x: screen.midX - editorWidth / 2,
               y: screen.midY - editorHeight / 2,
               width: editorWidth,
               height: editorHeight)
    }

    private func captureFrame(in screen: NSRect) -> NSRect {
        let h = max(60, captureContentSize.height)
        return NSRect(x: screen.midX - captureWidth / 2,
                      y: anchorCenterY - h / 2,
                      width: captureWidth,
                      height: h)
    }

    private func currentScreenVisibleFrame() -> NSRect? {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? self.screen ?? NSScreen.main
        return screen?.visibleFrame
    }

    /// Resize the panel to match the capture content height while anchored to
    /// `anchorCenterY`. No-op unless we're in capture mode and not mid-edit.
    private func captureContentDidChange(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        captureContentSize = size
        guard mode == .capture else { return }
        let newFrame = NSRect(x: frame.minX,
                              y: anchorCenterY - size.height / 2,
                              width: captureWidth,
                              height: size.height)
        guard abs(newFrame.height - frame.height) > 0.5 else { return }
        setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - Activation policy

    private func promoteToRegular() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func demoteToAccessory() {
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
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

    // MARK: - Window overrides

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { mode == .editor }

    /// Intercept ⌘F before CodeMirror/WebKit can treat it as "find", and use it
    /// to toggle between the two surfaces.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            toggleMode()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func orderOut(_ sender: Any?) {
        canDismissOnBlur = false
        super.orderOut(sender)
    }

    override func resignKey() {
        super.resignKey()
        guard mode == .capture, canDismissOnBlur else { return }
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
        if let chrome = editorContainer.chromeHost as? NSHostingView<EditorChromeBar> {
            chrome.rootView = editorChromeBar(title: url.lastPathComponent)
        }
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
    // Watch the capture file for external writes (notably the capture flow
    // appending todos) and reload the editor. Atomic writes replace the file
    // via temp+rename, orphaning our fd, so we re-open on `.rename`/`.delete`.

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

// MARK: - Editor container view

/// Lays out the slim chrome bar (pinned to the top) above the WKWebView.
/// Plain manual layout — no Auto Layout — to match the rest of the panel.
private final class EditorContainerView: NSView {
    private(set) var chromeHost: NSView?
    private var web: NSView?
    private let chromeHeight: CGFloat = 38

    func configure(chrome: NSView, web: NSView) {
        self.chromeHost = chrome
        self.web = web
        chrome.wantsLayer = true
        addSubview(web)
        addSubview(chrome)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let chromeHost, let web else { return }
        chromeHost.frame = NSRect(x: 0, y: bounds.height - chromeHeight,
                                  width: bounds.width, height: chromeHeight)
        web.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - chromeHeight)
    }
}

// MARK: - Editor chrome bar

/// Slim header shown above the editor: back to capture, the filename, close.
private struct EditorChromeBar: View {
    let title: String
    let onBack: () -> Void
    let onClose: () -> Void

    private let iconColor = Color(hex: 0x6E6E72)
    private let titleColor = Color(hex: 0x4A4A52)
    private let surface = Color.white

    var body: some View {
        HStack(spacing: 8) {
            chromeButton(systemName: "chevron.left", help: "Back to capture (⌘F)", action: onBack)
            Spacer(minLength: 8)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            chromeButton(systemName: "xmark", help: "Close", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: 0xF0F0F3))
                .frame(height: 1)
        }
    }

    private func chromeButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
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
