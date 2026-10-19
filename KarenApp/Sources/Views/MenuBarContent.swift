import SwiftUI

// ─── Menu Bar Content ─────────────────────────────────────────────────────────

struct MenuBarContent: View {
    @EnvironmentObject var karen: KarenCore

    var body: some View {
        Group {
            Label("K.A.R.E.N.", systemImage: "sparkle")
                .font(.headline)

            Divider()

            // Listening state
            if karen.isListening {
                Label("Listening…", systemImage: "mic.fill")
                    .foregroundStyle(KarenTheme.accent(for: karen.orbState))
            } else if karen.orbState == .speaking {
                Label("Speaking…", systemImage: "waveform")
                    .foregroundStyle(KarenTheme.accent(for: karen.orbState))
            } else {
                Label("Running in menu bar", systemImage: "sparkles")
                    .foregroundStyle(KarenTheme.accent(for: karen.orbState))
            }

            // Last reply
            if !karen.replyText.isEmpty {
                Text(karen.replyText)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button(karen.isListening ? "Stop Listening" : "Start Listening") {
                karen.toggleListening()
            }
            .keyboardShortcut("l")

            Button(karen.isMuted ? "Unmute" : "Mute") {
                karen.toggleMute()
            }

            Button(karen.wakeWordEnabled ? "Disable Wake Word" : "Enable Wake Word") {
                karen.toggleWakeWord()
            }

            Divider()

            Button("Open K.A.R.E.N.") {
                karen.showAssistantWindow()
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
    }
}
