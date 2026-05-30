import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Path", text: $appState.captureFilePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose…") { chooseFile() }
                }
                Text("Captured items are appended as `- [ ] …` lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Capture File")
            }

            Section {
                HStack {
                    Text("Hotkey")
                    Spacer()
                    KeyRecorderView(hotKey: $appState.hotKey)
                }
                Text("Click the field, then press your combo. Esc cancels. Requires at least one modifier (⌃⌥⇧⌘).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shortcut")
            }

            Section {
                Picker("Input font", selection: $appState.captureFontDesign) {
                    ForEach(CaptureFontDesign.allCases) { design in
                        Text(design.label)
                            .font(.system(size: 13, design: design.design))
                            .tag(design)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Preview")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("What needs doing?")
                        .font(.system(size: 17, design: appState.captureFontDesign.design))
                }
            } header: {
                Text("Appearance")
            }

            Section {
                Toggle("Append timestamp to each capture", isOn: $appState.includeTimestamp)
                if appState.includeTimestamp {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Preview")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("- [ ] buy milk \(FileWriter.createdMarker) \(FileWriter.timestampString(for: Date()))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Text("Uses the Obsidian Tasks plugin's `\(FileWriter.createdMarker)` (created) marker with `YYYY-MM-DD HH:MM`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Timestamp")
            }

            Section {
                Toggle("Vim keybindings in the editor", isOn: $appState.vimEnabled)
                Text("When off, the editor uses standard text editing. ⌘F still toggles the editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Editor")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
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
