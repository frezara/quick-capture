import AppKit
import Darwin
import WebKit

/// Window that hosts the WKWebView-backed CodeMirror editor for a single
/// markdown file. Loads `editor.html` from the app bundle, ships the file
/// contents to JS on `ready`, and persists edits when JS posts `save`.
final class EditorWindow: NSWindow {
    let fileURL: URL
    private let webView: WKWebView
    private let bridge: EditorBridge

    /// Last content we either wrote to disk or pushed to the editor. Used by
    /// the file-change watcher to ignore our own writes — without it, every
    /// save would loop back as an "external change" and overwrite the doc.
    private var lastSyncedContent: String = ""
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1

    deinit {
        stopWatching()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.bridge = EditorBridge()
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = fileURL.lastPathComponent
        representedURL = fileURL    // titlebar shows file icon + proxy-click menu
        contentView = webView
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")  // prevent white flash on load

        bridge.window = self
        config.userContentController.add(bridge, name: "editorBridge")

        // Window frame is autosaved per file path so each file opens where the
        // user last left it. Falls back to the default frame above on first open.
        setFrameAutosaveName("EditorWindow.\(fileURL.absoluteString.hashValue)")

        loadEditor()
    }

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

    /// Called by the JS side once CodeMirror has booted.
    fileprivate func sendInitialContent() {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        pushContent(text)
        startWatching()
    }

    /// Called by the JS side on debounced edits.
    fileprivate func write(_ content: String) {
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            lastSyncedContent = content
        } catch {
            NSLog("Editor failed to write \(fileURL.path): \(error)")
        }
    }

    private func pushContent(_ text: String) {
        lastSyncedContent = text
        guard let encoded = String(data: try! JSONEncoder().encode(text), encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.qcEditor.setContent(\(encoded))", completionHandler: nil)
    }

    // MARK: - File watching
    //
    // We watch the file for external writes — Quick Capture's capture panel
    // appending todos is the obvious one — and reload the editor when its
    // content changes. Atomic writes (`String.write(to:atomically:)` and
    // `Data.write(to:options:.atomic)`) replace the file via a temp+rename, so
    // our file descriptor becomes orphaned after each write. We re-open on
    // `.rename`/`.delete` events.

    private func startWatching() {
        stopWatching()
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleWatcherEvent()
        }
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
            // Short delay lets the atomic rename settle before we re-open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.reloadIfChanged()
                self?.startWatching()
            }
            return
        }

        reloadIfChanged()
    }

    private func reloadIfChanged() {
        let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        if current == lastSyncedContent { return }
        pushContent(current)
    }
}

/// WKWebView message handler bridging JS → Swift. JS posts JSON dicts of the
/// form `{ type: "ready" | "save", content?: String }` to `editorBridge`.
final class EditorBridge: NSObject, WKScriptMessageHandler {
    weak var window: EditorWindow?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            window?.sendInitialContent()
        case "save":
            if let content = dict["content"] as? String {
                window?.write(content)
            }
        default:
            break
        }
    }
}
