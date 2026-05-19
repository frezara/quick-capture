import AppKit
import SwiftUI

struct KeyRecorderView: View {
    @Binding var hotKey: HotKeyConfig
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? cancel() : startRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: recording ? "record.circle.fill" : "keyboard")
                    .foregroundStyle(recording ? Color.red : Color.secondary)
                Text(recording ? "Press a key combo…" : hotKey.displayString)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 80, alignment: .center)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .onDisappear { stopRecording() }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !recording else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // consume the event so it doesn't reach the focused field
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }

    private func cancel() {
        stopRecording()
    }

    private func handle(_ event: NSEvent) {
        // Esc cancels recording without changing anything.
        if event.keyCode == 53 { stopRecording(); return }

        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty else {
            // Plain keys would conflict with typing. Require at least one modifier.
            NSSound.beep()
            return
        }

        let newConfig = HotKeyConfig(
            keyCode: UInt32(event.keyCode),
            modifiers: mods.rawValue,
            displayName: Self.displayName(for: event)
        )

        // Refuse keys we can't translate back to a HotKey.Key
        guard newConfig.key != nil else {
            NSSound.beep()
            return
        }

        hotKey = newConfig
        stopRecording()
    }

    // MARK: - Display

    private static func displayName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49:  return "Space"
        case 36:  return "Return"
        case 76:  return "Enter"
        case 51:  return "Delete"
        case 48:  return "Tab"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}
