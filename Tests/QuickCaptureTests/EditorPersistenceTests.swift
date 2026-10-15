import XCTest
import WebKit
@testable import QuickCapture

private final class PersistenceTestBridge: NSObject, WKScriptMessageHandler {
    var receive: (([String: Any]) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { receive?(body) }
    }
}

@MainActor
final class EditorPersistenceTests: XCTestCase {
    private func loadEditor() async throws -> (WKWebView, PersistenceTestBridge) {
        let ready = expectation(description: "Editor ready")
        let bridge = PersistenceTestBridge()
        bridge.receive = { message in
            if message["type"] as? String == "ready" { ready.fulfill() }
        }
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "editorBridge")
        config.userContentController.addUserScript(WKUserScript(source: "window.testErrors=[]; console.error=(...args)=>window.testErrors.push(args.map(a=>a?.stack || String(a)).join(' '));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        let html = try XCTUnwrap(Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "dist"))
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        await fulfillment(of: [ready], timeout: 10)
        _ = try await web.evaluateJavaScript("window.qcEditor.setVimEnabled(false); window.qcEditor.setContent('original'); true")
        return (web, bridge)
    }

    func testWorkspaceNavigationAndInspectorPreserveDocument() async throws {
        let (web, _) = try await loadEditor()
        let content = "# Inbox\n\n## Work\n- [ ] Review design !!!\n  ![screen](attachments/test.png)\n\n## Personal\n- [ ] Book a table\n"
        let json = String(data: try JSONEncoder().encode(content), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("qcEditor.setContent(\(json)); qcEditor.revealLine(3); true")
        let details = try await web.evaluateJavaScript("document.querySelector('.qc-item-detail').textContent") as? String
        XCTAssertTrue(details?.contains("Review design") == true)
        XCTAssertTrue(details?.contains("High") == true)
        XCTAssertTrue(details?.contains("Attachments1") == true)
        _ = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.qc-sections button')).find(b => b.textContent.includes('Personal')).click(); true")
        let active = try await web.evaluateJavaScript("document.querySelector('.qc-sections button.active').textContent") as? String
        XCTAssertTrue(active?.contains("Personal") == true)
        let buffer = try await web.evaluateJavaScript("qcEditor.getContent()") as? String
        XCTAssertEqual(buffer, content)
        let disabled = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('[data-item-action]')).every(b => b.disabled)") as? Bool
        XCTAssertEqual(disabled, true, "A section heading cannot be refiled as an item")
    }

    func testWorkspaceUsesNativeActionsAndLeavesRoomForEditor() async throws {
        let (web, bridge) = try await loadEditor()
        let capture = expectation(description: "Capture routed through native bridge")
        bridge.receive = { message in
            if message["type"] as? String == "capture" { capture.fulfill() }
        }
        _ = try await web.evaluateJavaScript("document.querySelector('.qc-workspace-header button').click(); true")
        await fulfillment(of: [capture], timeout: 5)
        let fits = try await web.evaluateJavaScript("""
            (() => {
                const nav = document.querySelector('.qc-navigation').getBoundingClientRect();
                const editor = document.querySelector('.cm-scroller').getBoundingClientRect();
                const inspector = document.querySelector('.qc-inspector').getBoundingClientRect();
                return editor.left >= nav.right && editor.right <= inspector.left + 1 && editor.width >= 350;
            })()
            """) as? Bool
        XCTAssertEqual(fits, true, "Workspace columns must not overlap at the normal window size")
    }

    func testLongPreviewIsCompactAndSidebarActionsAlign() async throws {
        let (web, _) = try await loadEditor()
        let content = "# Inbox\n## Work\n- [ ] " + String(repeating: "A long task with useful context. ", count: 15)
        let json = String(data: try JSONEncoder().encode(content), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("qcEditor.setContent(\(json)); qcEditor.revealLine(2); true")
        let compact = try await web.evaluateJavaScript("document.querySelector('#qc-selected-preview').getBoundingClientRect().height <= 60") as? Bool
        XCTAssertEqual(compact, true)
        _ = try await web.evaluateJavaScript("document.querySelector('.qc-preview-toggle').click(); true")
        let expanded = try await web.evaluateJavaScript("document.querySelector('.qc-preview-toggle').getAttribute('aria-expanded')") as? String
        XCTAssertEqual(expanded, "true")
        let bounded = try await web.evaluateJavaScript("document.querySelector('#qc-selected-preview').getBoundingClientRect().height <= 160") as? Bool
        XCTAssertEqual(bounded, true)
        let aligned = try await web.evaluateJavaScript("""
            (() => {
                const rows = Array.from(document.querySelectorAll('.qc-inspector-actions .cm-sidebar-btn'));
                const icons = rows.map(b => b.querySelector('svg').getBoundingClientRect().left);
                const labels = rows.map(b => b.querySelector('span').getBoundingClientRect().left);
                const inspector = document.querySelector('.qc-inspector').getBoundingClientRect();
                const actions = document.querySelector('.qc-inspector-actions').getBoundingClientRect();
                const noSettings = !Array.from(document.querySelectorAll('button')).some(b => b.textContent.includes('Settings'));
                return noSettings && actions.bottom > inspector.bottom - 25 && rows.length === 2 && Math.max(...icons) - Math.min(...icons) < 1 && Math.max(...labels) - Math.min(...labels) < 1;
            })()
            """) as? Bool
        XCTAssertEqual(aligned, true)
    }

    func testImageSourceUsesVimWithoutHidingPreview() async throws {
        let (web, _) = try await loadEditor()
        let content = "# Inbox\n## Work\n- [ ] Task\n  ![first](attachments/test.png)\n  ![second](attachments/test.png)\n"
        let json = String(data: try JSONEncoder().encode(content), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("qcEditor.setContent(\(json)); qcEditor.setVimEnabled(true); qcEditor.revealLine(3); qcEditor.focus(); true")
        _ = try await web.evaluateJavaScript("qcEditor.attachmentLoaded('attachments/test.png', 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'); true")
        let count = try await web.evaluateJavaScript("document.querySelectorAll('.cm-attachment-img').length") as? Int
        XCTAssertEqual(count, 2)
        _ = try await web.evaluateJavaScript("qcEditor.invoke('imageSource'); true")
        let source = try await web.evaluateJavaScript("!!document.querySelector('.cm-attachment-source') && !document.querySelector('textarea, dialog, .cm-image-open')") as? Bool
        XCTAssertEqual(source, true, "Image source stays in the main Vim editor")
        _ = try await web.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key:'i',code:'KeyI',bubbles:true,cancelable:true})); document.execCommand('insertText', false, 'new-'); true")
        _ = try await web.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',code:'Escape',bubbles:true,cancelable:true})); true")
        let changed = try await web.evaluateJavaScript("qcEditor.getContent()") as? String
        XCTAssertTrue(changed?.contains("![first](new-attachments/test.png)") == true)
        let visible = try await web.evaluateJavaScript("document.querySelectorAll('.cm-attachment-img').length") as? Int
        XCTAssertEqual(visible, 2, "Preview remains while editing its source")
        _ = try await web.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key:'u',code:'KeyU',bubbles:true,cancelable:true})); true")
        let undone = try await web.evaluateJavaScript("qcEditor.getContent()") as? String
        XCTAssertEqual(undone, content)
        _ = try await web.evaluateJavaScript("qcEditor.invoke('imageSource'); true")
        let hidden = try await web.evaluateJavaScript("!document.querySelector('.cm-attachment-source') && document.querySelectorAll('.cm-attachment').length === 2") as? Bool
        XCTAssertEqual(hidden, true)
    }

    func testArchiveWaitsForSaveAndShortcutHintsUseRegistryValues() async throws {
        let (web, bridge) = try await loadEditor()
        let save = expectation(description: "Archive first requests save")
        let archive = expectation(description: "Archive follows save acknowledgement")
        var saveID: Int?
        var archived = false
        bridge.receive = { message in
            if message["type"] as? String == "save" { saveID = message["id"] as? Int; save.fulfill() }
            if message["type"] as? String == "archive" { archived = true; archive.fulfill() }
        }
        _ = try await web.evaluateJavaScript("qcEditor.setContent('- [ ] Original'); qcEditor.revealLine(0); qcEditor.focus(); document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight',metaKey:true,bubbles:true})); document.execCommand('insertText', false, ' changed'); true")
        _ = try await web.evaluateJavaScript("qcEditor.invoke('archive'); true")
        await fulfillment(of: [save], timeout: 5)
        XCTAssertFalse(archived)
        let id = try XCTUnwrap(saveID)
        _ = try await web.evaluateJavaScript("qcEditor.saveResult(\(id), null, null); true")
        await fulfillment(of: [archive], timeout: 5)
        _ = try await web.evaluateJavaScript("qcEditor.setShortcutHints({archive:'⌥⌘K', reorg:'⌥⌘J'}); true")
        let hints = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.qc-inspector-actions kbd')).map(k => k.textContent)") as? [String]
        XCTAssertEqual(hints, ["⌥⌘J", "⌥⌘K"])
    }

    func testBlankLineCannotReorganiseOrArchive() async throws {
        let (web, bridge) = try await loadEditor()
        let content = "# Inbox\n## Work\n\n- [x] Completed\n- [ ] Open\n"
        let json = String(data: try JSONEncoder().encode(content), encoding: .utf8)!
        let archive = expectation(description: "No archive on a blank line")
        archive.isInverted = true
        bridge.receive = { [weak web] message in
            if message["type"] as? String == "archive" { archive.fulfill() }
            if message["type"] as? String == "save", let id = message["id"] as? Int {
                web?.evaluateJavaScript("qcEditor.saveResult(\(id), null, null)", completionHandler: nil)
            }
        }
        _ = try await web.evaluateJavaScript("qcEditor.setContent(\(json)); qcEditor.revealLine(2); qcEditor.invoke('reorg'); qcEditor.invoke('archive'); true")
        let buffer = try await web.evaluateJavaScript("qcEditor.getContent()") as? String
        XCTAssertEqual(buffer, content)
        await fulfillment(of: [archive], timeout: 0.3)
        let disabled = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.qc-inspector-actions button')).every(b => b.disabled)") as? Bool
        XCTAssertEqual(disabled, true)
    }

    func testFirstEditAutosavesAndFailureKeepsBufferWithPersistentError() async throws {
        let (web, bridge) = try await loadEditor()
        let save = expectation(description: "First edit autosaved")
        var request: [String: Any]?
        bridge.receive = { message in
            if message["type"] as? String == "save" { request = message; save.fulfill() }
        }
        _ = try await web.evaluateJavaScript("window.qcEditor.focus(); document.execCommand('insertText', false, 'new '); true")
        await fulfillment(of: [save], timeout: 5)
        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent["expected"] as? String, "original")
        let content = try XCTUnwrap(sent["content"] as? String)
        XCTAssertTrue(content.contains("new "))
        let id = try XCTUnwrap(sent["id"] as? Int)
        _ = try await web.evaluateJavaScript("window.qcEditor.saveResult(\(id), 'Disk full', null); true")
        let buffer = try await web.evaluateJavaScript("window.qcEditor.getContent()") as? String
        XCTAssertEqual(buffer, content)
        let error = try await web.evaluateJavaScript("document.getElementById('qc-save-error').textContent") as? String
        XCTAssertTrue(error?.contains("Disk full") == true)
    }

    func testNativeFlushAwaitsBridgeAcknowledgement() async throws {
        let (web, bridge) = try await loadEditor()
        bridge.receive = { [weak web] message in
            guard message["type"] as? String == "save", let id = message["id"] as? Int else { return }
            web?.evaluateJavaScript("window.qcEditor.saveResult(\(id), null, null)", completionHandler: nil)
        }
        _ = try await web.evaluateJavaScript("window.qcEditor.focus(); document.execCommand('insertText', false, 'flush me '); true")
        let flushed = expectation(description: "Native flush completed")
        web.callAsyncJavaScript("return await window.qcEditor.flushSave()",
                                arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): XCTAssertEqual(value as? Bool, true)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            flushed.fulfill()
        }
        await fulfillment(of: [flushed], timeout: 5)
        let buffer = try await web.evaluateJavaScript("window.qcEditor.getContent()") as? String
        XCTAssertTrue(buffer?.contains("flush me ") == true)
    }

    func testExternalReloadPreservesDirtyBufferAndOffersConflictChoices() async throws {
        let (web, _) = try await loadEditor()
        _ = try await web.evaluateJavaScript("window.qcEditor.focus(); document.execCommand('insertText', false, 'mine '); true")
        // DOM input is observed by CodeMirror at the end of the JS turn;
        // native watcher messages arrive in a separate turn as well.
        _ = try await web.evaluateJavaScript("window.qcEditor.setContent('external'); true")
        let buffer = try await web.evaluateJavaScript("window.qcEditor.getContent()") as? String
        XCTAssertTrue(buffer?.contains("mine ") == true)
        let error = try await web.evaluateJavaScript("document.getElementById('qc-save-error').textContent") as? String
        XCTAssertTrue(error?.contains("Keep my edits") == true)
        XCTAssertTrue(error?.contains("Use disk version") == true)
    }
}
