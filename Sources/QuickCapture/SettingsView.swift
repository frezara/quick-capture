import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    var body: some View { SettingsForm(appState: appState) }
}

/// Split from `SettingsView` so the form gets `@Bindable` access (`$appState.…`)
/// to the environment's `AppState`.
private struct SettingsForm: View {
    @Bindable var appState: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        // Scrolls because the content is taller than any sensible default
        // window height, and grows further with every refile target. Before
        // this the window was pinned to 360pt and everything past Advanced was
        // unreachable (#116).
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.s4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(Typeface.ui(26, .bold)).tracking(-0.4).foregroundStyle(t.ink)
                    Text("Changes save as you make them.").font(Typeface.ui(13)).foregroundStyle(t.inkSecondary)
                }
                generalCard
                captureFileCard
                captureBoxCard
                refileTargetsSection
                OrganiserSettingsView()
                DisclosureGroup("Legacy development spool") { HandoffSettingsView() }
            }
            .padding(.horizontal, 30).padding(.vertical, 28)
            .frame(width: 680)
        }
        .background(t.sunken)
        .tint(t.accent)
        // Login Items can be changed in System Settings while this is open.
        .onAppear { loginEnabled = SMAppService.mainApp.status == .enabled }
    }

    // MARK: - Cards
    //
    // Grouped by what the setting AFFECTS, not by how advanced it is. The old
    // "Advanced" card held a capture-format option, an editor option and a
    // system option — it was where the leftovers went (#116).

    private var generalCard: some View {
        settingsCard("General") {
            settingsRow(
                label: "Capture shortcut",
                note: "Summons the capture box from anywhere. Click it, then press the new keys; Esc cancels."
            ) {
                KeyRecorderView(hotKey: $appState.hotKey)
            }
            rowDivider
            settingsRow(
                label: "Open at login",
                note: nil
            ) {
                settingsToggle(launchAtLoginBinding)
            }
        }
    }

    private var captureFileCard: some View {
        settingsCard("Capture file") {
            settingsRow(label: "File", note: nil) {
                HStack(spacing: Metrics.s2) {
                    TextField("", text: $appState.captureFilePath)
                        .textFieldStyle(.plain)
                        .font(Typeface.mono(12))
                        .foregroundStyle(t.ink)
                        .multilineTextAlignment(.trailing)
                        .truncationMode(.head)
                    Button("Choose…", action: chooseFile)
                        .buttonStyle(GhostButtonStyle(t: t))
                }
            }
            rowDivider
            settingsRow(
                label: "Add the time to each capture",
                note: "Writes Obsidian Tasks’ `\(FileWriter.createdMarker) YYYY-MM-DD HH:MM` after the text."
            ) {
                settingsToggle($appState.includeTimestamp)
            }
        }
    }

    private var captureBoxCard: some View {
        settingsCard("Capture box and editor") {
            // The sample is the row's own second line, rendered in the chosen
            // face — it was a separate row with its own icon square, which read
            // as a second setting (#116).
            settingsRow(label: "Input font") {
                Text("What needs doing?")
                    .font(appState.captureFontDesign.font(size: 13))
                    .foregroundStyle(t.inkSecondary)
            } control: {
                Picker("", selection: $appState.captureFontDesign) {
                    ForEach(CaptureFontDesign.allCases) { d in Text(d.label).tag(d) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            rowDivider
            settingsRow(
                label: "Vim keys in the editor",
                note: "When off, the editor uses standard editing keys. ⌥⌘I still switches to it."
            ) {
                settingsToggle($appState.vimEnabled)
            }
        }
    }

    /// The card plus its "Add Folder…" button. The button sits below the group
    /// rather than inside a row of its own — an action isn't a setting, and a
    /// row needs an icon square it has no business having.
    private var refileTargetsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.s2) {
            settingsCard("Refile targets") {
                if appState.refileTargets.isEmpty {
                    settingsRow(
                        label: "No targets yet",
                        note: "⌥⌘U in the editor files the item under your cursor into a target's `inbox.md`."
                    ) { EmptyView() }
                } else {
                    // Identity is the folder path, not the position, so a label
                    // being edited stays with its folder through a reorder.
                    ForEach($appState.refileTargets) { $target in
                        if target.id != appState.refileTargets.first?.id { rowDivider }
                        refileTargetRow($target)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Add folder…", action: addRefileTarget)
                    .buttonStyle(GhostButtonStyle(t: t))
                if appState.refileTargets.count > 1 {
                    Text("Drag to reorder. ⌥⌘U lists them in this order.")
                        .font(TypeScale.meta).foregroundStyle(t.inkSecondary)
                }
            }
            .padding(.leading, 2)
        }
    }

    private var rowDivider: some View {
        t.hairline.frame(height: 1)
    }

    private func settingsToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    // MARK: - Components

    private func settingsCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typeface.ui(13, .bold))
                .foregroundStyle(t.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .background(t.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusWell))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusWell).strokeBorder(t.border, lineWidth: 1))
        }
    }

    /// A row whose secondary line is explanatory text. `Text(.init(note))`
    /// rather than `Text(note)`: SwiftUI parses markdown only for
    /// `LocalizedStringKey`, so the plain-String overload rendered the
    /// backticks in these notes as literal characters (#116).
    private func settingsRow<Control: View>(
        label: String,
        note: String?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        settingsRow(label: label) {
            if let note {
                Text(.init(note))
                    .font(TypeScale.meta)
                    .foregroundStyle(t.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } control: {
            control()
        }
    }

    /// The general form: the second line is whatever the row wants it to be —
    /// a note, or the live font sample.
    private func settingsRow<Secondary: View, Control: View>(
        label: String,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Metrics.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Typeface.ui(13.5, .medium))
                    .foregroundStyle(t.ink)
                secondary()
            }
            Spacer(minLength: Metrics.s2)
            control()
        }
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, 12)
    }

    // MARK: - Refile targets

    private func refileTargetRow(_ binding: Binding<RefileTarget>) -> some View {
        let target = binding.wrappedValue
        return HStack(alignment: .center, spacing: Metrics.s2) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(t.inkTertiary)
                .help("Drag to reorder")
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                    .font(Typeface.ui(13.5, .medium))
                    .foregroundStyle(t.ink)
                Text(target.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(Typeface.mono(11.5))
                    .foregroundStyle(t.inkSecondary)
                    .truncationMode(.head)
                    .lineLimit(1)
            }
            Spacer(minLength: Metrics.s2)

            // The label was a borderless TextField, which gave no sign it could
            // be typed in (#116). A well — the same recipe as the capture
            // field — is what makes it read as an input.
            TextField("Label", text: binding.labelInput)
                .textFieldStyle(.plain)
                .font(Typeface.ui(12))
                .foregroundStyle(t.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: 96)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                        .fill(t.surfaceField)
                )

            Button("Remove") { appState.refileTargets.removeAll { $0.id == target.id } }
                .buttonStyle(GhostButtonStyle(t: t))
                .help("Remove this refile target")
        }
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, 10)
        .background(t.surface)
        // Reorder by dragging a row onto another; a row's identity is its
        // folder path. VoiceOver and keyboard users get the same moves as
        // actions.
        .draggable(target.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            appState.refileTargets = RefileTarget.moving(id, to: target.id, in: appState.refileTargets)
            return true
        }
        .accessibilityAction(named: "Move up") {
            appState.refileTargets = RefileTarget.moving(target.id, by: -1, in: appState.refileTargets)
        }
        .accessibilityAction(named: "Move down") {
            appState.refileTargets = RefileTarget.moving(target.id, by: 1, in: appState.refileTargets)
        }
    }

    private func addRefileTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder whose inbox.md should receive refiled items"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let standardized = url.standardizedFileURL
        guard !appState.refileTargets.contains(where: { $0.folderURL.standardizedFileURL == standardized }) else { return }
        appState.refileTargets.append(RefileTarget(path: url.path, label: nil))
    }

    // MARK: - Actions

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginEnabled },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else        { try SMAppService.mainApp.unregister() }
                    loginEnabled = SMAppService.mainApp.status == .enabled
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't update launch-at-login"
                    alert.informativeText = "\(error.localizedDescription)\n\nYou can also toggle this in System Settings → General → Login Items."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        )
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText
        ]
        panel.canCreateDirectories = true
        panel.message = "Choose a markdown file to append captures to"
        if panel.runModal() == .OK, let url = panel.url {
            appState.captureFilePath = url.path
        }
    }
}

// MARK: - Previews

#Preview("Settings · long path") {
    SettingsView()
        .environment({
            let s = AppState()
            s.captureFilePath = "/Users/fahadqazi/Documents/Notes/Personal/2024/quick-capture/inbox.md"
            return s
        }())
}

#Preview("Settings · short path") {
    SettingsView()
        .environment(AppState())
}
