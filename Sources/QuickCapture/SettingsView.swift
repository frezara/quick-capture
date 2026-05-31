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
                    note: "Items are appended as `- [ ] …` lines."
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
                t.border.frame(height: 1)
                settingsRow(
                    label: "Hotkey",
                    note: "Click, press your combo, Esc cancels. Needs ⌃⌥⇧⌘."
                ) {
                    KeyRecorderView(hotKey: $appState.hotKey)
                }
            }

            settingsCard("APPEARANCE") {
                settingsRow(label: "Input font", note: nil) {
                    Picker("", selection: $appState.captureFontDesign) {
                        ForEach(CaptureFontDesign.allCases) { d in Text(d.label).tag(d) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                t.border.frame(height: 1)
                settingsRow(label: "Font sample", note: nil, labelColor: t.inkSecondary) {
                    Text("What needs doing?")
                        .font(.system(size: 17, design: appState.captureFontDesign.design))
                        .foregroundStyle(t.ink)
                }
            }

            settingsCard("ADVANCED") {
                settingsRow(
                    label: "Append timestamp to each capture",
                    note: "Uses Obsidian Tasks `\(FileWriter.createdMarker)` marker — `YYYY-MM-DD HH:MM`."
                ) {
                    Toggle("", isOn: $appState.includeTimestamp).labelsHidden()
                }
                t.border.frame(height: 1)
                settingsRow(
                    label: "Vim keybindings",
                    note: "When off, standard editing. ⌘F still toggles the editor."
                ) {
                    Toggle("", isOn: $appState.vimEnabled).labelsHidden()
                }
                t.border.frame(height: 1)
                settingsRow(
                    label: "Launch at Login",
                    note: "App must be in /Applications for this to take effect."
                ) {
                    Toggle("", isOn: launchAtLoginBinding).labelsHidden()
                }
            }
        }
        .padding(Metrics.s3)
        .frame(width: 480)
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
                .foregroundStyle(t.inkTertiary)
            VStack(spacing: 0) { content() }
                .background(t.surface)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                        .strokeBorder(t.border, lineWidth: 1)
                )
        }
    }

    private func settingsRow<Control: View>(
        label: String,
        note: String?,
        labelColor: Color? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Metrics.s3) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(TypeScale.body)
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
        .padding(.vertical, 12)
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
            .font(TypeScale.code)
            .foregroundStyle(configuration.isPressed ? t.accentInk : t.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(configuration.isPressed ? t.accentSoft : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .strokeBorder(t.accent.opacity(0.5), lineWidth: 1)
            )
    }
}
