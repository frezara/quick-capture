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
            VStack(alignment: .leading, spacing: Metrics.s3) {
                Text("Settings").font(TypeScale.h1).foregroundStyle(t.ink)
                Text("A small tool, fitted to your workflow.").font(Typeface.ui(11)).foregroundStyle(t.inkSecondary)
                generalCard
                captureFileCard
                captureBoxCard
                editorCard
                refileTargetsSection
                OrganiserSettingsView()
                DisclosureGroup("Legacy development spool") { HandoffSettingsView() }
            }
            .padding(Metrics.s4)
            .frame(width: 680)
        }
        .background(t.surface)
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
        settingsCard("GENERAL") {
            settingsRow(
                label: "Global hotkey",
                note: "Click, press your combo, Esc cancels. Needs ⌃⌥⇧⌘.",
                symbol: "command"
            ) {
                KeyRecorderView(hotKey: $appState.hotKey)
            }
            rowDivider
            settingsRow(
                label: "Launch at Login",
                note: "Open Quick Capture automatically when you log in.",
                symbol: "power"
            ) {
                settingsToggle(launchAtLoginBinding)
            }
        }
    }

    private var captureFileCard: some View {
        settingsCard("CAPTURE FILE") {
            settingsRow(label: "Path", note: nil, symbol: "doc.text") {
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
                label: "Append timestamp to each capture",
                note: "Obsidian Tasks `\(FileWriter.createdMarker) YYYY-MM-DD HH:MM` marker.",
                symbol: "clock"
            ) {
                settingsToggle($appState.includeTimestamp)
            }
        }
    }

    private var captureBoxCard: some View {
        settingsCard("CAPTURE BOX") {
            // The sample is the row's own second line, rendered in the chosen
            // face — it was a separate row with its own icon square, which read
            // as a second setting (#116).
            settingsRow(label: "Input font", symbol: "textformat") {
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
        }
    }

    private var editorCard: some View {
        settingsCard("EDITOR") {
            settingsRow(
                label: "Vim keybindings",
                note: "When off, standard editing. ⌥⌘I still toggles the editor.",
                symbol: "terminal"
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
            settingsCard("REFILE TARGETS") {
                if appState.refileTargets.isEmpty {
                    settingsRow(
                        label: "No targets yet",
                        note: "⌥⌘U in the editor files the item under your cursor into a target's `inbox.md`.",
                        symbol: "folder"
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
            Button("Add Folder…", action: addRefileTarget)
                .buttonStyle(GhostButtonStyle(t: t))
                .padding(.leading, 2)
        }
    }

    private var rowDivider: some View {
        t.border.frame(height: 0.5).padding(.leading, 50)
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
        VStack(alignment: .leading, spacing: Metrics.s1) {
            Text(title)
                .font(TypeScale.caption)
                .tracking(Tracking.caption)
                .foregroundStyle(t.inkSecondary)
            VStack(spacing: 0) { content() }
                .groupedSurface(t)
        }
    }

    /// A row whose secondary line is explanatory text. `Text(.init(note))`
    /// rather than `Text(note)`: SwiftUI parses markdown only for
    /// `LocalizedStringKey`, so the plain-String overload rendered the
    /// backticks in these notes as literal characters (#116).
    private func settingsRow<Control: View>(
        label: String,
        note: String?,
        symbol: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        settingsRow(label: label, symbol: symbol) {
            if let note {
                Text(.init(note))
                    .font(TypeScale.caption)
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
        symbol: String? = nil,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Metrics.s2) {
            if let symbol {
                settingsIcon(symbol)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(Typeface.ui(12, .medium))
                    .foregroundStyle(t.ink)
                secondary()
            }
            Spacer(minLength: Metrics.s2)
            control()
        }
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, Metrics.s2)
    }

    private func settingsIcon(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
            .fill(t.accentSoft)
            .frame(width: 25, height: 25)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.accentInk)
            )
    }

    // MARK: - Refile targets

    private func refileTargetRow(_ binding: Binding<RefileTarget>) -> some View {
        let target = binding.wrappedValue
        return HStack(alignment: .center, spacing: Metrics.s2) {
            settingsIcon("folder")
            VStack(alignment: .leading, spacing: 3) {
                Text(target.displayName)
                    .font(Typeface.ui(12, .medium))
                    .foregroundStyle(t.ink)
                Text(target.path)
                    .font(TypeScale.caption)
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

            // Reorder and remove read as chrome, not as actions competing with
            // the accent — the accent means interaction elsewhere (ADR-0005).
            HStack(spacing: 2) {
                reorderButton("chevron.up", enabled: target.id != appState.refileTargets.first?.id) {
                    appState.refileTargets = RefileTarget.moving(target.id, by: -1, in: appState.refileTargets)
                }
                reorderButton("chevron.down", enabled: target.id != appState.refileTargets.last?.id) {
                    appState.refileTargets = RefileTarget.moving(target.id, by: 1, in: appState.refileTargets)
                }
            }
            Button { appState.refileTargets.removeAll { $0.id == target.id } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(t.inkSecondary)
            .help("Remove this refile target")
        }
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, Metrics.s2)
    }

    private func reorderButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? t.inkSecondary : t.inkSecondary.opacity(0.5))
        .disabled(!enabled)
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
