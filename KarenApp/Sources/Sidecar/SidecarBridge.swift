import Foundation
import Network

// ─── Sidecar Bridge ───────────────────────────────────────────────────────────
//
// Manages the lifecycle of the Python sidecar process and a WebSocket
// connection over a localhost WebSocket.
// Protocol is documented in sidecar/karen_sidecar/protocol.py

final class SidecarBridge: NSObject {
    // Callbacks (called on main queue)
    var onReply:       ((String, String, Bool) -> Void)?
    var onStateChange: ((String) -> Void)?
    var onError:       ((String, String) -> Void)?

    // Exposed for MemoryView
    var memory: MemoryBridge?

    private var process: Process?
    private var webSocketTask: URLSessionWebSocketTask?
    private let socketURL = URL(string: "ws://127.0.0.1:18765")
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var isStopped = false

    override init() {
        memory = MemoryBridge()
        super.init()
    }

    // MARK: - Connect

    func connect() {
        launchSidecar()
        // Give the sidecar 2 s to start listening
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.openWebSocket()
        }
    }

    // MARK: - Sidecar process lifecycle

    private func launchSidecar() {
        // Resolve path: repo root / sidecar
        let repoRoot = findRepoRoot()
        let sidecarPath = repoRoot + "/sidecar"
        let venvPython = sidecarPath + "/.venv/bin/python3"
        let systemPython = "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3"

        let python = FileManager.default.fileExists(atPath: venvPython) ? venvPython : systemPython

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-m", "karen_sidecar"]
        proc.currentDirectoryURL = URL(fileURLWithPath: sidecarPath)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = sidecarPath
        if environment["KAREN_LLM_PROVIDER"] == nil {
            environment["KAREN_LLM_PROVIDER"] = "mock"
        }
        proc.environment = environment

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            if let line = String(data: fh.availableData, encoding: .utf8), !line.isEmpty {
                print("[sidecar] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        do {
            try proc.run()
            self.process = proc
            print("[SidecarBridge] Sidecar PID: \(proc.processIdentifier)")
        } catch {
            print("[SidecarBridge] Failed to launch sidecar: \(error)")
        }
    }

    private func findRepoRoot() -> String {
        // Walk up from Bundle path to find the karen repo root (contains Package.swift)
        var url = URL(fileURLWithPath: Bundle.main.bundlePath)
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        // Fallback: use the scratch directory
        return NSHomeDirectory() + "/.gemini/antigravity/scratch/karen"
    }

    // MARK: - WebSocket

    private func openWebSocket() {
        guard !isStopped else { return }
        guard let url = socketURL else { return }

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        schedulePing()
        receiveMessages()
        print("[SidecarBridge] WebSocket opened")
    }

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self, !isStopped else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg {
                    self.handleMessage(text)
                }
                self.receiveMessages()
            case .failure(let err):
                print("[SidecarBridge] Receive error: \(err) — reconnecting in 2s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.openWebSocket()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case "state":
                if let state = json["state"] as? String {
                    self.onStateChange?(state)
                }
            case "reply":
                let id    = json["id"]   as? String ?? ""
                let text  = json["text"] as? String ?? ""
                let speak = json["speak"] as? Bool   ?? true
                self.onReply?(id, text, speak)
            case "error":
                let id  = json["id"]      as? String ?? ""
                let msg = json["message"] as? String ?? "Unknown error"
                self.onError?(id, msg)
            case "action":
                // Action requiring confirmation — forward to KarenCore via notification
                NotificationCenter.default.post(name: .karenActionRequest, object: json)
            case "pong":
                break
            default:
                print("[SidecarBridge] Unknown message type: \(type)")
            }
        }
    }

    // MARK: - Send

    func sendTranscript(id: String, text: String, final isFinal: Bool) async throws {
        let msg: [String: Any] = ["type": "transcript", "id": id, "text": text, "final": isFinal]
        let data = try JSONSerialization.data(withJSONObject: msg)
        guard let str = String(data: data, encoding: .utf8) else { return }
        try await webSocketTask?.send(.string(str))
    }

    func sendCancel(id: String) {
        let msg: [String: Any] = ["type": "cancel", "id": id]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(str)) { _ in }
    }

    // MARK: - Ping

    private func schedulePing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.webSocketTask?.send(.string("{\"type\":\"ping\"}")) { _ in }
        }
    }

    // MARK: - Shutdown

    func stop() {
        isStopped = true
        pingTimer?.invalidate()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        process?.terminate()
    }
}

// ─── Notification names ───────────────────────────────────────────────────────
extension Notification.Name {
    static let karenActionRequest = Notification.Name("KarenActionRequest")
}

// ─── Memory Bridge (thin wrapper around Python memory via SQLite) ─────────────
// Reads the same SQLite file the Python sidecar writes.

import SQLite3

final class MemoryBridge {
    private let dbPath: String
    private var db: OpaquePointer?

    init() {
        let dir = NSHomeDirectory() + "/Library/Application Support/KAREN"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbPath = dir + "/memory.sqlite"
        openDB()
    }

    private func openDB() {
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            sqlite3_exec(db, """
                CREATE TABLE IF NOT EXISTS memories (
                    id TEXT PRIMARY KEY, content TEXT NOT NULL,
                    approved INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
                )
            """, nil, nil, nil)
        }
    }

    func list_approved() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id,content,created_at FROM memories WHERE approved=1 AND deleted=0 ORDER BY created_at DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id  = String(cString: sqlite3_column_text(stmt, 0))
                let con = String(cString: sqlite3_column_text(stmt, 1))
                let ts  = String(cString: sqlite3_column_text(stmt, 2))
                rows.append(["id": id, "content": con, "created_at": ts])
            }
        }
        sqlite3_finalize(stmt)
        return rows
    }

    /// Explicitly adding an item in the Memory panel counts as user approval.
    func add_approved(_ content: String) {
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO memories(id,content,approved,created_at,deleted) VALUES(?,?,1,?,0)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let id = UUID().uuidString
        let createdAt = ISO8601DateFormatter().string(from: Date())
        _ = id.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
        _ = cleaned.withCString { sqlite3_bind_text(stmt, 2, $0, -1, transient) }
        _ = createdAt.withCString { sqlite3_bind_text(stmt, 3, $0, -1, transient) }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func delete(_ id: String) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE memories SET deleted=1 WHERE id=?", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    deinit { sqlite3_close(db) }
}
