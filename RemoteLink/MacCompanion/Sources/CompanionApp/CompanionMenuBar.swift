import AppKit
import CompanionCore

@MainActor
public final class CompanionMenuBar: NSObject, NSMenuDelegate, CompanionSyncEngineDelegate {
    private var statusItem: NSStatusItem!
    private let engine: CompanionSyncEngine
    private let configStore: ConfigStore
    private let launchAgent: LaunchAgentService
    private let journal: ResponseJournal

    private var statusMenuItem: NSMenuItem!
    private var pendingMenuItem: NSMenuItem!
    private var lastSyncMenuItem: NSMenuItem!
    private var launchAgentMenuItem: NSMenuItem!

    public init(engine: CompanionSyncEngine) {
        self.engine = engine
        self.configStore = .shared
        self.launchAgent = .shared
        self.journal = .shared
        super.init()

        setupStatusItem()
        engine.delegate = self
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemVisuals()

        let menu = NSMenu()
        menu.delegate = self

        let titleItem = NSMenuItem(title: "K.A.R.E.N. Remote Companion", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        statusMenuItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        pendingMenuItem = NSMenuItem(title: "Pending Requests: 0", action: nil, keyEquivalent: "")
        pendingMenuItem.isEnabled = false
        menu.addItem(pendingMenuItem)

        lastSyncMenuItem = NSMenuItem(title: "Last Sync: Never", action: nil, keyEquivalent: "")
        lastSyncMenuItem.isEnabled = false
        menu.addItem(lastSyncMenuItem)

        menu.addItem(NSMenuItem.separator())

        let syncNowItem = NSMenuItem(title: "Sync Now", action: #selector(onSyncNow), keyEquivalent: "s")
        syncNowItem.target = self
        menu.addItem(syncNowItem)

        let pairItem = NSMenuItem(title: "Pair Android Phone...", action: #selector(onPairPhone), keyEquivalent: "p")
        pairItem.target = self
        menu.addItem(pairItem)

        let testItem = NSMenuItem(title: "Send Test Action Prompt...", action: #selector(onSendTest), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())

        launchAgentMenuItem = NSMenuItem(title: "Start at Login", action: #selector(onToggleLaunchAgent), keyEquivalent: "")
        launchAgentMenuItem.target = self
        launchAgentMenuItem.state = launchAgent.isInstalled() ? .on : .off
        menu.addItem(launchAgentMenuItem)

        let viewLogItem = NSMenuItem(title: "Open Response Journal...", action: #selector(onOpenJournal), keyEquivalent: "")
        viewLogItem.target = self
        menu.addItem(viewLogItem)

        let configItem = NSMenuItem(title: "Edit Cloud Configuration...", action: #selector(onOpenConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Companion", action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateStatusItemVisuals() {
        guard let button = statusItem.button else { return }

        let indicator: String
        switch engine.state {
        case .connected:
            indicator = "🔵"
        case .reconnecting:
            indicator = "🟡"
        case .offline:
            indicator = "⚪️"
        }

        let pending = engine.pendingCount
        if pending > 0 {
            button.title = "\(indicator) K (\(pending))"
        } else {
            button.title = "\(indicator) K"
        }
    }

    // MARK: - CompanionSyncEngineDelegate

    public func syncEngineStateDidChange(_ state: ConnectionState) {
        updateStatusItemVisuals()
        switch state {
        case .connected:
            self.statusMenuItem.title = "Status: Connected (Cloud D1)"
        case .reconnecting:
            self.statusMenuItem.title = "Status: Reconnecting / Syncing..."
        case .offline:
            self.statusMenuItem.title = "Status: Offline"
        }
    }

    public func syncEnginePendingCountDidChange(_ count: Int) {
        updateStatusItemVisuals()
        self.pendingMenuItem.title = "Pending Requests: \(count)"
    }

    public func syncEngineLastSyncDidChange(_ date: Date?) {
        if let date = date {
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            self.lastSyncMenuItem.title = "Last Sync: \(formatter.string(from: date))"
        } else {
            self.lastSyncMenuItem.title = "Last Sync: Never"
        }
    }

    public func syncEngineDidReceiveResponse(_ record: NotificationRequestRecord) {
        NSLog("[K.A.R.E.N. Remote] Received response for '%@': %@", record.title, record.outcome?.rawValue ?? "UNKNOWN")
    }

    // MARK: - Actions

    @objc private func onSyncNow() {
        engine.syncNow()
    }

    @objc private func onPairPhone() {
        Task {
            do {
                let session = try await engine.createPairingSession()
                let alert = NSAlert()
                alert.messageText = "K.A.R.E.N. Remote Pairing Code"
                alert.informativeText = """
                Enter this 6-character code in your K.A.R.E.N. Remote Android app:

                \(session.pairingCode)

                Relay Server: \(configStore.load().cloudURL.absoluteString)
                Code expires in 5 minutes.
                """
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Copy Code")
                let resp = alert.runModal()
                if resp == .alertSecondButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.pairingCode, forType: .string)
                }
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func onSendTest() {
        Task {
            do {
                _ = try await engine.sendNotification(
                    title: "K.A.R.E.N. Test Request",
                    message: "Can you confirm you received this cloud test push notification?",
                    details: "Sent from macOS Companion across different networks.",
                    actions: ["APPROVE", "DENY", "REPLY"]
                )
            } catch {
                NSLog("[K.A.R.E.N. Remote] Failed to send test: %@", error.localizedDescription)
            }
        }
    }

    @objc private func onToggleLaunchAgent() {
        do {
            if launchAgent.isInstalled() {
                try launchAgent.uninstall()
                launchAgentMenuItem.state = .off
            } else {
                try launchAgent.install()
                launchAgentMenuItem.state = .on
            }
        } catch {
            NSLog("[K.A.R.E.N. Remote] LaunchAgent error: %@", error.localizedDescription)
        }
    }

    @objc private func onOpenJournal() {
        let url = journal.journalFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func onOpenConfig() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".karen/remote_link_cloud_config.json")
        NSWorkspace.shared.open(url)
    }

    @objc private func onQuit() {
        NSApplication.shared.terminate(nil)
    }
}
