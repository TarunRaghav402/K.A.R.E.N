import AppKit
import Foundation
import CompanionCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: CompanionMenuBar?
    private let engine = CompanionSyncEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = CompanionMenuBar(engine: engine)
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }
}

@main
struct CompanionAppMain {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            K.A.R.E.N. Remote Companion (macOS)
            Usage:
              karen-companion                  Start menu-bar companion app
              karen-companion --daemon         Start menu-bar companion app (LaunchAgent mode)
              karen-companion --pair           Generate 6-character pairing code for Android app
              karen-companion --status         Check Cloud API status and pending requests
              karen-companion --sync           Perform a single synchronization cycle
              karen-companion --send <t> <m>   Send a test notification request (title, message)
              karen-companion --install-agent  Install LaunchAgent to start companion on login
              karen-companion --uninstall-agent Remove LaunchAgent
            """)
            exit(0)
        }

        if args.contains("--pair") || args.contains("-p") {
            let config = ConfigStore.shared.load()
            let client = CloudAPIClient()
            print("Connecting to \(config.cloudURL)...")
            do {
                let session = try await client.createPairingSession(config: config)
                print("\n=======================================================")
                print("           K.A.R.E.N. REMOTE PAIRING CODE              ")
                print("=======================================================")
                print("   Pairing Code : \(session.pairingCode)")
                print("   Expires In   : 5 minutes")
                print("   Relay Server : \(config.cloudURL)")
                print("   Mac Name     : \(session.macName)")
                print("=======================================================")
                print("\nInstructions:")
                print("1. Open K.A.R.E.N. Remote app on your Android phone.")
                print("2. Enter the 6-character code '\(session.pairingCode)' and tap 'Pair Device'.")
                print("3. Both devices will be linked via Cloudflare D1 and FCM.")
                print("")
            } catch {
                print("✗ Failed to create pairing session: \(error.localizedDescription)")
            }
            exit(0)
        }

        if args.contains("--install-agent") {
            do {
                try LaunchAgentService.shared.install()
                print("✓ LaunchAgent installed successfully at ~/Library/LaunchAgents/com.karen.remote.companion.plist")
                exit(0)
            } catch {
                print("✗ Failed to install LaunchAgent: \(error.localizedDescription)")
                exit(1)
            }
        }

        if args.contains("--uninstall-agent") {
            do {
                try LaunchAgentService.shared.uninstall()
                print("✓ LaunchAgent uninstalled successfully")
                exit(0)
            } catch {
                print("✗ Failed to uninstall LaunchAgent: \(error.localizedDescription)")
                exit(1)
            }
        }

        if args.contains("--status") {
            let config = ConfigStore.shared.load()
            let client = CloudAPIClient()
            print("Connecting to \(config.cloudURL)...")
            do {
                let health = try await client.checkHealth(config: config)
                print("✓ Service: \(health.service) (Status: \(health.status), Storage: \(health.durableStorage ?? "d1"), FCM: \(health.fcmConfigured ?? false))")
                let snapshot = try await client.fetchSyncSnapshot(config: config)
                print("  Pending Requests: \(snapshot.pendingRequests.count)")
                print("  Unprocessed Responses: \(snapshot.unprocessedResponses.count)")
                print("  Paired Devices: \(snapshot.effectiveDevices.count)")
            } catch {
                print("✗ Error connecting to Cloud API: \(error.localizedDescription)")
            }
            exit(0)
        }

        if args.contains("--sync") {
            let engine = CompanionSyncEngine()
            print("Performing sync...")
            await engine.performSync()
            print("✓ Sync finished. Status: \(engine.state.rawValue), Pending: \(engine.pendingCount)")
            exit(0)
        }

        if let sendIdx = args.firstIndex(of: "--send"), sendIdx + 2 < args.count {
            let title = args[sendIdx + 1]
            let message = args[sendIdx + 2]
            let engine = CompanionSyncEngine()
            print("Sending notification request '\(title)'...")
            do {
                let req = try await engine.sendNotification(title: title, message: message)
                print("✓ Request created. ID: \(req.requestId), Status: \(req.status.rawValue)")
            } catch {
                print("✗ Failed to send: \(error.localizedDescription)")
            }
            exit(0)
        }

        // Default mode: Run as accessory Menu Bar application
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // No dock icon, no automatic windows!
        app.run()
    }
}
