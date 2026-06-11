import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var scheme
    private var t: Theme { scheme == .dark ? .dark : .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard("FILE & SHORTCUT") {
                settingsRow(
                    label: "Path",
                    note: "Items are appended as `- [ ] …` lines.",
                    symbol: "doc.text",
                    iconColor: Color(0x007AFF)
                ) {
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
                t.border.frame(height: 0.5).padding(.leading, 50)
                settingsRow(
                    label: "Hotkey",
                    note: "Click, press your combo, Esc cancels. Needs ⌃⌥⇧⌘.",
                    symbol: "command",
                    iconColor: Color(0x5856D6)
                ) {
                    KeyRecorderView(hotKey: $appState.hotKey)
                }
            }

            settingsCard("APPEARANCE") {
                settingsRow(label: "Input font", note: nil, symbol: "textformat", iconColor: Color(0x8E8E93)) {
                    Picker("", selection: $appState.captureFontDesign) {
                        ForEach(CaptureFontDesign.allCases) { d in Text(d.label).tag(d) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                t.border.frame(height: 0.5).padding(.leading, 50)
                settingsRow(label: "Font sample", note: nil, labelColor: t.inkSecondary, symbol: "text.quote", iconColor: Color(0x8E8E93)) {
                    Text("What needs doing?")
                        .font(.system(size: 17, design: appState.captureFontDesign.design))
                        .foregroundStyle(t.ink)
                }
            }

            settingsCard("ADVANCED") {
                settingsRow(
                    label: "Append timestamp to each capture",
                    note: "Uses Obsidian Tasks `\(FileWriter.createdMarker)` marker — `YYYY-MM-DD HH:MM`.",
                    symbol: "clock",
                    iconColor: Color(0x8E8E93)
                ) {
                    Toggle("", isOn: $appState.includeTimestamp).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                t.border.frame(height: 0.5).padding(.leading, 50)
                settingsRow(
                    label: "Vim keybindings",
                    note: "When off, standard editing. ⌃⌘E still toggles the editor.",
                    symbol: "terminal",
                    iconColor: Color(0x34C759)
                ) {
                    Toggle("", isOn: $appState.vimEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                t.border.frame(height: 0.5).padding(.leading, 50)
                settingsRow(
                    label: "Auto-attach screenshot window",
                    note: "Screenshots newer than this pre-attach to the capture box. ⌘⇧S pulls in the latest anytime.",
                    symbol: "camera",
                    iconColor: Color(0x30B0C7)
                ) {
                    Picker("", selection: $appState.screenshotAttachWindow) {
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                        Text("10 minutes").tag(600.0)
                        Text("Any age").tag(AppState.attachWindowAny)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                t.border.frame(height: 0.5).padding(.leading, 50)
                settingsRow(
                    label: "Launch at Login",
                    note: "App must be in /Applications for this to take effect.",
                    symbol: "power",
                    iconColor: Color(0xFF9500)
                ) {
                    Toggle("", isOn: launchAtLoginBinding).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }

            settingsCard("REFILE TARGETS") {
                if appState.refileTargets.isEmpty {
                    settingsRow(
                        label: "No targets yet",
                        note: "⌃⌘R in the editor files the item under your cursor into a target's inbox.md.",
                        symbol: "folder",
                        iconColor: Color(0xFF9F0A)
                    ) {
                        Button("Add Folder…", action: addRefileTarget)
                            .buttonStyle(SettingsGhostButton(t: t))
                    }
                } else {
                    ForEach(appState.refileTargets.indices, id: \.self) { index in
                        refileTargetRow(index: index)
                        t.border.frame(height: 0.5).padding(.leading, 50)
                    }
                    settingsRow(label: "Add another destination", note: nil, symbol: "plus", iconColor: Color(0x8E8E93)) {
                        Button("Add Folder…", action: addRefileTarget)
                            .buttonStyle(SettingsGhostButton(t: t))
                    }
                }
            }
        }
        .padding(Metrics.s3)
        .frame(width: 520)
        .background(t.bg)
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

    private func settingsRow<Control: View>(
        label: String,
        note: String?,
        labelColor: Color? = nil,
        symbol: String? = nil,
        iconColor: Color = Color(0x8E8E93),
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Metrics.s2) {
            if let symbol {
                settingsIcon(symbol, iconColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(Typeface.ui(13))
                    .foregroundStyle(labelColor ?? t.ink)
                if let note {
                    Text(note)
                        .font(TypeScale.caption)
                        .foregroundStyle(t.inkTertiary)
                }
            }
            Spacer()
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
            TextField("Label", text: labelBinding(index))
                .textFieldStyle(.plain)
                .font(Typeface.ui(12))
                .foregroundStyle(t.ink)
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
            Button { moveRefileTarget(from: index, to: index - 1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(t.accent)
            .disabled(index == 0)
            Button { moveRefileTarget(from: index, to: index + 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .foregroundStyle(t.accent)
            .disabled(index == appState.refileTargets.count - 1)
            Button { removeRefileTarget(at: index) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(t.inkTertiary)
        }
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, 12)
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
