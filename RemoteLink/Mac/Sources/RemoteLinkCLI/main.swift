import Foundation
import RemoteLinkMac

// ANSI Colors for K.A.R.E.N. Neon Aesthetic
enum ANSI {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let cyan = "\u{001B}[36m"
    static let brightCyan = "\u{001B}[96m"
    static let green = "\u{001B}[32m"
    static let brightGreen = "\u{001B}[92m"
    static let yellow = "\u{001B}[33m"
    static let brightYellow = "\u{001B}[93m"
    static let red = "\u{001B}[31m"
    static let brightRed = "\u{001B}[91m"
    static let magenta = "\u{001B}[35m"
}

func printHeader() {
    print("""
    \(ANSI.brightCyan)\(ANSI.bold)
    ╔══════════════════════════════════════════════════════════════════╗
    ║                 K.A.R.E.N. REMOTE LINK CONTROLLER                ║
    ║             macOS ⇄ Android Notification & Response              ║
    ╚══════════════════════════════════════════════════════════════════╝
    \(ANSI.reset)
    """)
}

func printStatusBadge(_ status: RequestStatus) -> String {
    switch status {
    case .created:
        return "\(ANSI.dim)[CREATED]\(ANSI.reset)"
    case .sent:
        return "\(ANSI.brightCyan)[SENT]\(ANSI.reset)"
    case .delivered:
        return "\(ANSI.brightYellow)[DELIVERED]\(ANSI.reset)"
    case .waiting:
        return "\(ANSI.yellow)[WAITING FOR PHONE]\(ANSI.reset)"
    case .responded:
        return "\(ANSI.brightGreen)[RESPONDED]\(ANSI.reset)"
    case .expired:
        return "\(ANSI.red)[EXPIRED]\(ANSI.reset)"
    case .cancelled:
        return "\(ANSI.magenta)[CANCELLED]\(ANSI.reset)"
    case .deliveryFailed:
        return "\(ANSI.brightRed)[DELIVERY FAILED]\(ANSI.reset)"
    }
}

func printOutcomeBadge(_ outcome: RequestOutcome?) -> String {
    guard let outcome else { return "\(ANSI.dim)None\(ANSI.reset)" }
    switch outcome {
    case .approved:
        return "\(ANSI.brightGreen)\(ANSI.bold)✓ APPROVED BY PHONE\(ANSI.reset)"
    case .denied:
        return "\(ANSI.brightRed)\(ANSI.bold)✗ DENIED BY PHONE\(ANSI.reset)"
    case .replied:
        return "\(ANSI.brightCyan)\(ANSI.bold)💬 REPLIED BY PHONE\(ANSI.reset)"
    case .expired:
        return "\(ANSI.red)⏱ EXPIRED (No response received)\(ANSI.reset)"
    case .cancelled:
        return "\(ANSI.magenta)⊘ CANCELLED BY MAC\(ANSI.reset)"
    case .deliveryFailed:
        return "\(ANSI.brightRed)⚠ DELIVERY FAILED\(ANSI.reset)"
    }
}

@main
struct RemoteLinkCLIMain {
    static func main() async {
        let args = CommandLine.arguments
        var serverURL = URL(string: "http://127.0.0.1:8765")!

        if let serverIdx = args.firstIndex(of: "--server"), serverIdx + 1 < args.count {
            if let customURL = URL(string: args[serverIdx + 1]) {
                serverURL = customURL
            }
        }

        let client = RemoteLinkClient(baseURL: serverURL)

        // Non-interactive command flags
        if args.contains("--pair") {
            await handlePairing(client: client)
            return
        } else if args.contains("--send-approval") {
            await handleSendNotification(client: client, type: "approval", title: "K.A.R.E.N. Request", message: "K.A.R.E.N. is waiting for your decision.", actions: ["APPROVE", "DENY"])
            return
        } else if args.contains("--send-question") {
            await handleSendNotification(client: client, type: "question", title: "K.A.R.E.N. Needs Your Response", message: "Should I continue with this task?", actions: ["YES", "NO", "REPLY"])
            return
        } else if args.contains("--send-reply") {
            await handleSendNotification(client: client, type: "text_response", title: "Message from K.A.R.E.N.", message: "Please provide the information I requested.", actions: ["REPLY"])
            return
        } else if args.contains("--status") {
            await handleStatus(client: client)
            return
        }

        // Interactive terminal menu loop
        printHeader()
        print("\(ANSI.dim)Relay Server: \(serverURL.absoluteString)\(ANSI.reset)\n")

        // Start background WebSocket event listener
        client.startEventStream { event, payload in
            if event == "device_paired" {
                let name = payload["device_name"] as? String ?? "Phone"
                print("\n\(ANSI.brightGreen)⚡ [EVENT] Device '\(name)' just paired successfully!\(ANSI.reset)")
            } else if event == "request_delivered" {
                let reqId = payload["request_id"] as? String ?? ""
                print("\n\(ANSI.brightYellow)📬 [EVENT] Request \(reqId.prefix(8)) was DELIVERED to phone.\(ANSI.reset)")
            } else if event == "request_responded" {
                let outcome = payload["outcome"] as? String ?? ""
                let reply = payload["reply_text"] as? String
                print("\n\(ANSI.brightGreen)💬 [EVENT] Phone responded with: \(outcome)\(reply != nil ? " - '\(reply!)'" : "")\(ANSI.reset)")
            }
        }

        var running = true
        while running {
            printMenu()
            guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { break }

            switch line {
            case "1":
                await handlePairing(client: client)
            case "2":
                await handleSendNotification(
                    client: client,
                    type: "approval",
                    title: "K.A.R.E.N. Request",
                    message: "K.A.R.E.N. is waiting for your decision.",
                    actions: ["APPROVE", "DENY"]
                )
            case "3":
                await handleSendNotification(
                    client: client,
                    type: "question",
                    title: "K.A.R.E.N. Needs Your Response",
                    message: "Should I continue with this task?",
                    actions: ["YES", "NO", "REPLY"]
                )
            case "4":
                await handleSendNotification(
                    client: client,
                    type: "text_response",
                    title: "Message from K.A.R.E.N.",
                    message: "Please provide the information I requested.",
                    actions: ["REPLY"]
                )
            case "5":
                await handleCustomNotification(client: client)
            case "6":
                await handleStatus(client: client)
            case "7":
                await handleListPending(client: client)
            case "8":
                await handleCancelRequest(client: client)
            case "9":
                await handleRevokeDevice(client: client)
            case "0", "q", "exit", "quit":
                print("\n\(ANSI.dim)Exiting K.A.R.E.N. Remote Link.\(ANSI.reset)")
                running = false
            default:
                print("\(ANSI.red)Invalid choice. Please select 0-9.\(ANSI.reset)")
            }
        }
    }

    static func printMenu() {
        print("""
        \(ANSI.bold)Select an option:\(ANSI.reset)
          \(ANSI.brightCyan)[1]\(ANSI.reset) Pair with Android Phone (Generate Code / QR Payload)
          \(ANSI.brightCyan)[2]\(ANSI.reset) Send Type A: Approval Notification (APPROVE / DENY)
          \(ANSI.brightCyan)[3]\(ANSI.reset) Send Type B: Question Notification (YES / NO / REPLY)
          \(ANSI.brightCyan)[4]\(ANSI.reset) Send Type C: Text Response Notification (REPLY)
          \(ANSI.brightCyan)[5]\(ANSI.reset) Send Custom Notification
          \(ANSI.brightCyan)[6]\(ANSI.reset) Check Connection & Paired Devices Status
          \(ANSI.brightCyan)[7]\(ANSI.reset) View Active / Pending Requests
          \(ANSI.brightCyan)[8]\(ANSI.reset) Cancel a Pending Request
          \(ANSI.brightCyan)[9]\(ANSI.reset) Revoke Paired Device
          \(ANSI.dim)[0] Exit\(ANSI.reset)
        """)
        print("\(ANSI.bold)> \(ANSI.reset)", terminator: "")
    }

    // MARK: - Actions

    static func handlePairing(client: RemoteLinkClient) async {
        print("\n\(ANSI.brightCyan)─── Generating Device Pairing Session ───\(ANSI.reset)")
        do {
            let session = try await client.createPairingSession()
            print("""

            \(ANSI.bold)Pairing Code for Android Phone:\(ANSI.reset)
            ╔═════════════════════════════════════╗
            ║            \(ANSI.brightGreen)\(ANSI.bold)\(session.pairingCode)\(ANSI.reset)                   ║
            ╚═════════════════════════════════════╝

            \(ANSI.dim)1. Open the 'K.A.R.E.N. Remote' app on your Samsung phone.\(ANSI.reset)
            \(ANSI.dim)2. Enter the 6-character code above (or scan QR payload).\(ANSI.reset)
            \(ANSI.dim)3. Code expires in 5 minutes.\(ANSI.reset)

            \(ANSI.yellow)Waiting for phone to pair... (Press Enter to cancel waiting)\(ANSI.reset)
            """)

            let pollTask = Task {
                try await client.pollPairingStatus(sessionId: session.sessionId, timeoutSeconds: 300)
            }

            let result = try await pollTask.value
            if result.isPaired {
                print("\n\(ANSI.brightGreen)\(ANSI.bold)✓ SUCCESS: Device successfully paired with K.A.R.E.N.!\(ANSI.reset)")
                print("\(ANSI.dim)Paired Device ID: \(result.pairedDeviceId ?? "Unknown")\(ANSI.reset)\n")
            }
        } catch {
            print("\n\(ANSI.red)Pairing error: \(error.localizedDescription)\(ANSI.reset)\n")
        }
    }

    static func handleSendNotification(
        client: RemoteLinkClient,
        type: String,
        title: String,
        message: String,
        actions: [String],
        details: String? = nil,
        timeout: Int = 120
    ) async {
        print("\n\(ANSI.brightCyan)─── Creating Notification Request ───\(ANSI.reset)")
        print("\(ANSI.dim)Title:   \(title)")
        print("Message: \(message)")
        print("Actions: \(actions.joined(separator: " | "))")
        print("Timeout: \(timeout) seconds\(ANSI.reset)\n")

        do {
            let req = try await client.createNotification(
                type: type,
                title: title,
                message: message,
                details: details,
                actions: actions,
                timeoutSeconds: timeout
            )

            print("Request ID: \(ANSI.bold)\(req.requestId)\(ANSI.reset)")
            print("Status:     \(printStatusBadge(req.status))\n")
            print("\(ANSI.yellow)Waiting for response from Android phone... (Timeout: \(timeout)s)\(ANSI.reset)")

            let startTime = Date()
            let finalRecord = try await client.waitForResponse(
                requestId: req.requestId,
                timeoutSeconds: timeout,
                pollIntervalSeconds: 0.5
            ) { updated in
                let elapsed = Int(Date().timeIntervalSince(startTime))
                print("\rStatus Update: \(printStatusBadge(updated.status)) (\(elapsed)s elapsed)       ", terminator: "")
                fflush(stdout)
            }

            print("\n")
            print("╔══════════════════════════════════════════════════════════════════╗")
            print("║                      FINAL RESPONSE RECEIVED                     ║")
            print("╚══════════════════════════════════════════════════════════════════╝")
            print("Request ID:   \(finalRecord.requestId)")
            print("Outcome:      \(printOutcomeBadge(finalRecord.outcome))")

            if let reply = finalRecord.replyText, !reply.isEmpty {
                print("Exact Reply:  \(ANSI.brightCyan)\(ANSI.bold)\"\(reply)\"\(ANSI.reset)")
            }

            if let responder = finalRecord.responderDeviceId {
                print("Responder:    Device \(responder)")
            }

            if let delivered = finalRecord.deliveredAt {
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                print("Delivered At: \(formatter.string(from: Date(timeIntervalSince1970: delivered)))")
            }

            if let responded = finalRecord.respondedAt {
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                print("Responded At: \(formatter.string(from: Date(timeIntervalSince1970: responded)))")
            }
            print("────────────────────────────────────────────────────────────────────\n")

        } catch {
            print("\n\(ANSI.red)Failed to complete request: \(error.localizedDescription)\(ANSI.reset)\n")
        }
    }

    static func handleCustomNotification(client: RemoteLinkClient) async {
        print("\n\(ANSI.brightCyan)─── Send Custom Notification ───\(ANSI.reset)")
        print("Enter Title [K.A.R.E.N. Alert]: ", terminator: "")
        var title = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = "K.A.R.E.N. Alert" }

        print("Enter Message: ", terminator: "")
        let message = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Action required on your Mac."

        print("Enter Details (optional, press Enter to skip): ", terminator: "")
        let detailsInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (detailsInput?.isEmpty == false) ? detailsInput : nil

        print("Enter Actions (comma separated) [APPROVE, DENY, REPLY]: ", terminator: "")
        let actionsInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let actions = actionsInput.isEmpty
            ? ["APPROVE", "DENY", "REPLY"]
            : actionsInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        print("Enter Timeout in seconds [120]: ", terminator: "")
        let timeoutInput = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "120"
        let timeout = Int(timeoutInput) ?? 120

        await handleSendNotification(
            client: client,
            type: "custom",
            title: title,
            message: message,
            actions: actions,
            details: details,
            timeout: timeout
        )
    }

    static func handleStatus(client: RemoteLinkClient) async {
        print("\n\(ANSI.brightCyan)─── Connection & Paired Devices ───\(ANSI.reset)")
        do {
            let health = try await client.checkHealth()
            print("Relay Status:            \(ANSI.brightGreen)\(health.status.uppercased())\(ANSI.reset)")
            print("Paired Devices:          \(health.pairedDevicesCount)")
            print("Active Mac Clients:      \(health.connectedMacClients)")
            print("Active Phone Clients:    \(health.connectedPhoneClients)")
            print("FCM Push Configured:     \(health.fcmConfigured ? "\(ANSI.green)YES\(ANSI.reset)" : "\(ANSI.yellow)Direct/WS Mode\(ANSI.reset)")")

            let devices = try await client.listDevices()
            if devices.isEmpty {
                print("\n\(ANSI.yellow)No devices paired yet. Choose option [1] to pair your phone.\(ANSI.reset)\n")
            } else {
                print("\n\(ANSI.bold)Registered Devices:\(ANSI.reset)")
                for (idx, dev) in devices.enumerated() {
                    let lastSeen = Date(timeIntervalSince1970: dev.lastSeenAt)
                    let formatter = RelativeDateTimeFormatter()
                    let relString = formatter.localizedString(for: lastSeen, relativeTo: Date())
                    print("  [\(idx + 1)] \(ANSI.brightCyan)\(dev.deviceName)\(ANSI.reset) (ID: \(dev.deviceId)) — Last seen \(relString)")
                }
                print("")
            }
        } catch {
            print("\(ANSI.red)Failed to fetch status: \(error.localizedDescription)\(ANSI.reset)\n")
        }
    }

    static func handleListPending(client: RemoteLinkClient) async {
        print("\n\(ANSI.brightCyan)─── Active Pending Requests ───\(ANSI.reset)")
        do {
            let requests = try await client.getPendingRequests()
            if requests.isEmpty {
                print("\(ANSI.dim)No pending requests at this time.\(ANSI.reset)\n")
                return
            }

            for req in requests {
                let remaining = max(0, Int(req.expiresAt - Date().timeIntervalSince1970))
                print("""
                • Request ID: \(req.requestId)
                  Title:      \(req.title)
                  Message:    \(req.message)
                  Status:     \(printStatusBadge(req.status))
                  Expires In: \(remaining) seconds
                  Actions:    \(req.actions.joined(separator: ", "))
                """)
            }
            print("")
        } catch {
            print("\(ANSI.red)Error fetching requests: \(error.localizedDescription)\(ANSI.reset)\n")
        }
    }

    static func handleCancelRequest(client: RemoteLinkClient) async {
        print("\n\(ANSI.brightCyan)─── Cancel Pending Request ───\(ANSI.reset)")
        print("Enter Request ID to cancel: ", terminator: "")
        guard let reqId = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !reqId.isEmpty else {
            print("\(ANSI.dim)Cancelled.\(ANSI.reset)\n")
            return
        }

        do {
            let cancelled = try await client.cancelRequest(requestId: reqId)
            print("\(ANSI.brightGreen)✓ Request \(cancelled.requestId) successfully cancelled.\(ANSI.reset)\n")
        } catch {
            print("\(ANSI.red)Failed to cancel request: \(error.localizedDescription)\(ANSI.reset)\n")
        }
    }

    static func handleRevokeDevice(client: RemoteLinkClient) async {
        print("\n\(ANSI.brightCyan)─── Revoke Paired Device ───\(ANSI.reset)")
        do {
            let devices = try await client.listDevices()
            if devices.isEmpty {
                print("\(ANSI.dim)No devices paired.\(ANSI.reset)\n")
                return
            }

            for (idx, dev) in devices.enumerated() {
                print("  [\(idx + 1)] \(dev.deviceName) (ID: \(dev.deviceId))")
            }
            print("Select device number to revoke (or press Enter to skip): ", terminator: "")
            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let num = Int(input), num >= 1, num <= devices.count else {
                print("\(ANSI.dim)No device revoked.\(ANSI.reset)\n")
                return
            }

            let target = devices[num - 1]
            let success = try await client.revokeDevice(deviceId: target.deviceId)
            if success {
                print("\(ANSI.brightGreen)✓ Device '\(target.deviceName)' has been revoked.\(ANSI.reset)\n")
            }
        } catch {
            print("\(ANSI.red)Failed to revoke device: \(error.localizedDescription)\(ANSI.reset)\n")
        }
    }
}

