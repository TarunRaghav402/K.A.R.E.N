import SwiftUI
import AppKit

@main
struct KarenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var karen = KarenCore()

    var body: some Scene {
        WindowGroup("K.A.R.E.N.") {
            ContentView()
                .environmentObject(karen)
                .frame(minWidth: 680, minHeight: 560)
                .background(KarenTheme.panel(for: karen.orbState))
                .tint(KarenTheme.accent(for: karen.orbState))
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("K.A.R.E.N.") {
                Button("Toggle Listening") { karen.toggleListening() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Toggle Mute") { karen.toggleMute() }
                    .keyboardShortcut("m", modifiers: .command)
                Button("Stop Speaking") { karen.stopSpeaking() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Permissions Center") { karen.showPermissions = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Settings") { karen.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra("K.A.R.E.N.", systemImage: karen.menuBarIcon) {
            MenuBarContent()
                .environmentObject(karen)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // run as background agent
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}
