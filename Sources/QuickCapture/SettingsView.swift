import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        // Scrolls because the content is taller than any sensible default
        // window height, and grows further with every refile target. Before
        // this the window was pinned to 360pt and everything past Advanced was
        // unreachable (#116).
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                generalCard
                captureFileCard
                captureBoxCard
                editorCard
                refileTargetsSection
            }
            .padding(Metrics.s3)
            .frame(width: 520)
        }
        .background(t.bg)
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
                symbol: "command",
                iconColor: Color(0x5856D6)
            ) {
                KeyRecorderView(hotKey: $appState.hotKey)
            }
            rowDivider
            settingsRow(
                label: "Launch at Login",
                note: "App must be in /Applications for this to take effect.",
                symbol: "power",
                iconColor: Color(0xFF9500)
            ) {
                settingsToggle(launchAtLoginBinding)
            }
        }
    }

    private var captureFileCard: some View {
        settingsCard("CAPTURE FILE") {
            settingsRow(label: "Path", note: nil, symbol: "doc.text", iconColor: Color(0x007AFF)) {
                HStack(spacing: Metrics.s2) {
                    TextField("", text: $appState.captureFilePath)
                        .textFieldStyle(.plain)
                        .font(Typeface.mono(12))
                        .foregroundStyle(t.ink)
                        .multilineTextAlignment(.trailing)
                        .truncationMode(.head)
                    Button("Choose…", action: chooseFile)
                        .buttonStyle(SettingsGhostButton(t: t))
                }
            }
            rowDivider
            settingsRow(
                label: "Append timestamp to each capture",
                note: "Obsidian Tasks `\(FileWriter.createdMarker) YYYY-MM-DD HH:MM` marker.",
                symbol: "clock",
                iconColor: Color(0x8E8E93)
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
            settingsRow(label: "Input font", symbol: "textformat", iconColor: Color(0x8E8E93)) {
                Text("What needs doing?")
                    .font(.system(size: 13, design: appState.captureFontDesign.design))
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
                symbol: "terminal",
                iconColor: Color(0x34C759)
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
                        symbol: "folder",
                        iconColor: Color(0xFF9F0A)
                    ) { EmptyView() }
                } else {
                    ForEach(appState.refileTargets.indices, id: \.self) { index in
                        if index > 0 { rowDivider }
                        refileTargetRow(index: index)
                    }
                }
            }
            Button("Add Folder…", action: addRefileTarget)
                .buttonStyle(SettingsGhostButton(t: t))
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
                .background(t.group)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(t.borderStrong, lineWidth: 0.5)
                )
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
        iconColor: Color = Color(0x8E8E93),
        @ViewBuilder control: () -> Control
    ) -> some View {
        settingsRow(label: label, symbol: symbol, iconColor: iconColor) {
            if let note {
                Text(.init(note))
                    .font(TypeScale.caption)
                    .foregroundStyle(t.inkTertiary)
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
        iconColor: Color = Color(0x8E8E93),
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Metrics.s2) {
            if let symbol {
                settingsIcon(symbol, iconColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(Typeface.ui(13))
                    .foregroundStyle(t.ink)
                secondary()
            }
            Spacer(minLength: Metrics.s2)
            control()
        }
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, 11)
    }

    /// System-Settings-style row icon: a small rounded square with a vertical
    /// gradient and a white SF Symbol. The one place (besides tag hues and
    /// priority orbs) where colour appears.
    private func settingsIcon(_ symbol: String, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.85), color],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
            )
    }

    // MARK: - Refile targets

    private func refileTargetRow(index: Int) -> some View {
        let target = appState.refileTargets[index]
        return HStack(alignment: .center, spacing: Metrics.s2) {
            settingsIcon("folder", Color(0xFF9F0A))
            VStack(alignment: .leading, spacing: 3) {
                Text(target.displayName)
                    .font(Typeface.ui(13))
                    .foregroundStyle(t.ink)
                Text(target.path)
                    .font(TypeScale.caption)
                    .foregroundStyle(t.inkTertiary)
                    .truncationMode(.head)
                    .lineLimit(1)
            }
            Spacer(minLength: Metrics.s2)

            // The label was a borderless TextField, which gave no sign it could
            // be typed in (#116). A well — the same recipe as the capture
            // field — is what makes it read as an input.
            TextField("Label", text: labelBinding(index))
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
                reorderButton("chevron.up", enabled: index > 0) {
                    moveRefileTarget(from: index, to: index - 1)
                }
                reorderButton("chevron.down", enabled: index < appState.refileTargets.count - 1) {
                    moveRefileTarget(from: index, to: index + 1)
                }
            }
            Button { removeRefileTarget(at: index) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(t.inkTertiary)
            .help("Remove this refile target")
        }
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, 11)
    }

    private func reorderButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? t.inkSecondary : t.inkTertiary.opacity(0.5))
        .disabled(!enabled)
    }

    /// Maps the target's optional label to a non-optional text binding; a blank
    /// value clears the label (so the dropdown falls back to the basename).
    private func labelBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { appState.refileTargets.indices.contains(index) ? (appState.refileTargets[index].label ?? "") : "" },
            set: { newValue in
                guard appState.refileTargets.indices.contains(index) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                appState.refileTargets[index].label = trimmed.isEmpty ? nil : newValue
            }
        )
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

    private func removeRefileTarget(at index: Int) {
        guard appState.refileTargets.indices.contains(index) else { return }
        appState.refileTargets.remove(at: index)
    }

    private func moveRefileTarget(from: Int, to: Int) {
        var targets = appState.refileTargets
        guard targets.indices.contains(from), to >= 0, to < targets.count else { return }
        let item = targets.remove(at: from)
        targets.insert(item, at: to)
        appState.refileTargets = targets
    }

    // MARK: - Actions

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else        { try SMAppService.mainApp.unregister() }
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
        .environmentObject({
            let s = AppState()
            s.captureFilePath = "/Users/fahadqazi/Documents/Notes/Personal/2024/quick-capture/inbox.md"
            return s
        }())
}

#Preview("Settings · short path") {
    SettingsView()
        .environmentObject(AppState())
}

// MARK: - Ghost button

private struct SettingsGhostButton: ButtonStyle {
    let t: Theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.ui(12))
            .foregroundStyle(t.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(configuration.isPressed ? t.chipHover : t.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .strokeBorder(t.borderStrong, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 0.5, y: 0.5)
    }
}
