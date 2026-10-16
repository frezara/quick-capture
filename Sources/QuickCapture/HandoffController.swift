import AppKit
import SwiftUI

@MainActor @Observable
final class HandoffController {
    static let shared = HandoffController()
    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "organiser.enabled") } }
    var spoolPath: String { didSet { UserDefaults.standard.set(spoolPath, forKey: "organiser.spool") } }
    var workspace: String { didSet { UserDefaults.standard.set(workspace, forKey: "organiser.workspace") } }
    var records: [HandoffRecord] = []
    var pendingImports: [HandoffPendingImport] = []
    var status = "Organiser delivery history"
    var warnings: [String] = []
    private let installation: String
    let store: HandoffStore
    private var worker: Task<Void, Never>?
    private var window: NSWindow?
    private var importing = false
    private var polling = false
    private var watchedPath = ""
    private var watcher: DispatchSourceFileSystemObject?
    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "organiser.enabled")
        spoolPath = d.string(forKey: "organiser.spool") ?? ""
        workspace = d.string(forKey: "organiser.workspace") ?? UUID().uuidString.lowercased()
        installation = d.string(forKey: "organiser.installation") ?? UUID().uuidString.lowercased()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickCapture/Handoffs")
        store = HandoffStore(root: root)
        d.set(workspace, forKey: "organiser.workspace"); d.set(installation, forKey: "organiser.installation")
    }
    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                watchReceipts()
                await poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    private func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        do {
            try await store.deliverDue(enabled: enabled)
            records = try await store.records()
            warnings = try await store.warnings()
            pendingImports = try await store.pendingImports()
        } catch { status = "Delivery needs attention; local content is retained." }
    }
    private func watchReceipts() {
        let path = URL(fileURLWithPath: spoolPath).appendingPathComponent("receipts").path
        guard path != watchedPath else { return }
        watcher?.cancel(); watcher = nil
        let fd = open(path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { watchedPath = ""; return }
        watchedPath = path
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.watchedPath = ""
                await self.poll()
            }
        }
        source.resume(); watcher = source
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the local organiser spool folder. Pending sends keep their original destination."
        if panel.runModal() == .OK, let url = panel.url { spoolPath = url.resolvingSymlinksInPath().path }
    }
    func send(sourceID: String, body: String, sourceFile: URL, asNew: Bool) {
        guard !importing else { showHistory(); return }
        guard enabled, !spoolPath.isEmpty, UUID(uuidString: workspace) != nil else {
            status = "Choose a spool folder and valid workspace UUID, then enable delivery in Settings."
            showHistory(); return
        }
        importing = true; status = "Importing for organiser…"
        let spool = URL(fileURLWithPath: spoolPath), workspace = workspace
        Task {
            defer { importing = false }
            do {
                let handoffID: String
                do {
                    handoffID = try await store.enqueue(sourceID: sourceID, body: body, sourceFile: sourceFile, spool: spool,
                                                workspace: workspace, installation: installation, asNew: asNew)
                } catch HandoffError.missing(let paths) {
                    let alert = NSAlert()
                    alert.messageText = "Attachments are missing or unreadable"
                    alert.informativeText = paths.joined(separator: "\n") + "\n\nThe source and its links remain unchanged. Omitted files will not be delivered."
                    alert.addButton(withTitle: "Keep for Recovery")
                    alert.addButton(withTitle: "Send Without Missing Attachments")
                    guard alert.runModal() == .alertSecondButtonReturn else {
                        status = "Send paused; source and incomplete import retained."
                        return
                    }
                    handoffID = try await store.enqueue(sourceID: sourceID, body: body, sourceFile: sourceFile, spool: spool,
                        workspace: workspace, installation: installation, asNew: asNew, omit: Set(paths))
                }
                records = try await store.records()
                status = records.first(where: { $0.id == handoffID })?.state == "delivered"
                    ? "Previously delivered. The original receipt is shown below."
                    : "Queued for organiser. The saved source remains editable."
            } catch { status = (error as? HandoffError)?.localizedDescription ?? "Could not queue delivery. The saved source is retained." }
            showHistory()
        }
    }
    func resumeImport(_ key: String) {
        guard !importing else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                do { _ = try await store.resumeImport(key) }
                catch HandoffError.missing(let paths) {
                    let alert = NSAlert()
                    alert.messageText = "Attachments are missing or unreadable"
                    alert.informativeText = paths.joined(separator: "\n")
                    alert.addButton(withTitle: "Keep for Recovery")
                    alert.addButton(withTitle: "Send Without Missing Attachments")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                    _ = try await store.resumeImport(key, omit: Set(paths))
                }
                status = "Queued for organiser."
                await poll()
            } catch { status = (error as? HandoffError)?.localizedDescription ?? "Import remains available for recovery." }
        }
    }
    func retry(_ id: String) {
        Task {
            do { try await store.retry(id); records = try await store.records() }
            catch { status = "Could not retry; content is retained." }
        }
    }
    func showHistory() {
        start()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Organiser deliveries"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HandoffHistoryView(controller: self))
            w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HandoffSettingsView: View {
    @Bindable var controller = HandoffController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ORGANISER").font(.headline)
            Toggle("Enable organiser delivery", isOn: $controller.enabled)
            Text("Send an item from the editor. Ordinary capture and refile stay unchanged.").font(.caption)
            HStack { Text(controller.spoolPath.isEmpty ? "No spool folder selected" : controller.spoolPath).lineLimit(1); Button("Choose Folder…") { controller.chooseFolder() } }
            TextField("Workspace UUID", text: $controller.workspace)
            Text("Use the same workspace UUID in the development receiver. Changing it affects new sends only.").font(.caption)
            Button("Delivery History…") { controller.showHistory() }
        }.padding()
    }
}
struct HandoffHistoryView: View {
    let controller: HandoffController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(controller.status)
            if !controller.enabled { Text("Delivery is paused.").foregroundStyle(.secondary) }
            ForEach(controller.warnings, id: \.self) { Text($0).font(.caption) }
            ForEach(controller.pendingImports) { pending in
                HStack {
                    Text(pending.body.components(separatedBy: "\n").first ?? "Interrupted import").lineLimit(1)
                    Button("Resume Import") { controller.resumeImport(pending.id) }
                }
            }
            List(controller.records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.manifest.request.payload.capture.body_markdown.components(separatedBy: "\n").first ?? "Item").lineLimit(2)
                    Text(label(record.state)).font(.headline)
                    Text("Handoff \(record.id)").font(.caption).textSelection(.enabled)
                    if let error = record.error { Text("Reason: \(error)").font(.caption) }
                    if let receipt = record.receipt {
                        Text("Accepted \(receipt.accepted_at) · item \(receipt.organiser_item_id)").font(.caption).textSelection(.enabled)
                    } else {
                        Button("Retry") { controller.retry(record.id) }.disabled(!controller.enabled)
                    }
                }.padding(.vertical, 4)
            }
            Text("Delivered means accepted by the organiser receiver. Availability on other devices is not verified.").font(.caption).foregroundStyle(.secondary)
        }.padding().frame(minWidth: 520, minHeight: 340)
    }
    private func label(_ state: String) -> String {
        switch state {
        case "delivered": return "Delivered"
        case "needs_attention": return "Delivery needs attention"
        default: return "Waiting for organiser"
        }
    }
}
