import Foundation
import Network

// ─── Sidecar Bridge ───────────────────────────────────────────────────────────
//
// Manages the lifecycle of the Python sidecar process and a WebSocket
// connection over a localhost WebSocket.
// Protocol is documented in sidecar/karen_sidecar/protocol.py

final class SidecarBridge: NSObject {
    private static let registryLock = NSLock()
    private static let activeBridges = NSHashTable<SidecarBridge>.weakObjects()

    static func stopAll() {
        registryLock.lock()
        let bridges = activeBridges.allObjects
        registryLock.unlock()
        bridges.forEach { $0.stop() }
    }

    // Callbacks (called on main queue)
    var onReply:       ((String, String, String, Bool) -> Void)?
    var onStateChange: ((String) -> Void)?
    var onError:       ((String, String) -> Void)?
    var onAction:      ((String, String, [String: Any]) -> Void)?

    // Exposed for MemoryView
    var memory: MemoryBridge?

    private var process: Process?
    private var webSocketTask: URLSessionWebSocketTask?
    private let socketURL = URL(string: "ws://127.0.0.1:18765")
    private var pingTimer: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var isStopped = false
    private var isConnecting = false
    private var isSocketReady = false

    private enum BridgeError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            "K.A.R.E.N.’s voice service is still starting. Please try again in a moment."
        }
    }

    override init() {
        memory = MemoryBridge()
        super.init()
        Self.registryLock.lock()
        Self.activeBridges.add(self)
        Self.registryLock.unlock()
    }

    deinit {
        stop()
        Self.registryLock.lock()
        Self.activeBridges.remove(self)
        Self.registryLock.unlock()
    }

    // MARK: - Connect

    func connect() {
        launchSidecar()
        // Let the sidecar bind its local port; requests arriving during startup
        // wait briefly for the socket instead of disappearing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.openWebSocket()
        }
    }

    // MARK: - Sidecar process lifecycle

    private func launchSidecar() {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: Bundle.main.bundlePath)
        let packagedSidecarDirectory = resources.appendingPathComponent("KarenSidecar", isDirectory: true)
        let onedirExecutable = packagedSidecarDirectory.appendingPathComponent("KarenSidecar").path
        let onefileExecutable = resources.appendingPathComponent("KarenSidecar").path
        let isOnedirPackage = FileManager.default.isExecutableFile(atPath: onedirExecutable)
        let isOnefilePackage = FileManager.default.isExecutableFile(atPath: onefileExecutable)
        let isPackaged = isOnedirPackage || isOnefilePackage

        let executable: String
        let arguments: [String]
        let workingDirectory: URL
        if isOnedirPackage {
            executable = onedirExecutable
            arguments = []
            workingDirectory = packagedSidecarDirectory
        } else if isOnefilePackage {
            // GitHub releases contain a frozen Python sidecar, so users do not
            // need Python, a checkout, or a virtual environment installed.
            executable = onefileExecutable
            arguments = []
            workingDirectory = resources
        } else {
            guard let repoRoot = findRepoRoot() else {
                onError?("", "K.A.R.E.N. couldn't find its project folder. Run it from scripts/run.sh in the Karen folder.")
                print("[SidecarBridge] Project root not found; sidecar was not launched")
                return
            }
            let sidecarPath = repoRoot + "/sidecar"
            let venvPython = sidecarPath + "/.venv/bin/python3"
            let systemPython = "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3"
            let python = FileManager.default.isExecutableFile(atPath: venvPython) ? venvPython : systemPython
            guard FileManager.default.isExecutableFile(atPath: python),
                  FileManager.default.fileExists(atPath: sidecarPath + "/karen_sidecar/__main__.py") else {
                onError?("", "K.A.R.E.N.'s Python 3.13 voice service is missing from the selected project folder.")
                print("[SidecarBridge] Python sidecar runtime or package is missing at \(sidecarPath)")
                return
            }
            executable = python
            arguments = ["-m", "karen_sidecar"]
            workingDirectory = URL(fileURLWithPath: sidecarPath)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        if let tavilyKey = SearchCredentialStore.loadTavilyKey() {
            environment["KAREN_SEARCH_PROVIDER"] = "tavily"
            environment["KAREN_TAVILY_API_KEY"] = tavilyKey
        }
        if !isPackaged, let repoRoot = findRepoRoot() {
            environment["PYTHONPATH"] = repoRoot + "/sidecar"
        }
        if environment["KAREN_LLM_PROVIDER"] == nil {
            environment["KAREN_LLM_PROVIDER"] = "mock"
        }
        proc.environment = environment

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe
        proc.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async {
                guard let self, !self.isStopped else { return }
                self.process = nil
                let reason = terminatedProcess.terminationReason == .uncaughtSignal ? "signal" : "exit"
                let status = terminatedProcess.terminationStatus
                print("[SidecarBridge] Sidecar ended by \(reason) with status \(status)")
                self.onError?("", "K.A.R.E.N.’s local voice service stopped (\(reason) \(status)).")
            }
        }
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
            onError?("", "K.A.R.E.N.'s voice service couldn't start: \(error.localizedDescription)")
        }
    }

    private func findRepoRoot() -> String? {
        // The installed app lives in ~/Applications, so its bundle is no longer
        // inside the checkout. The launcher records the active checkout in Info.plist.
        if let configuredRoot = Bundle.main.object(forInfoDictionaryKey: "KARENProjectRoot") as? String,
           isKarenProjectRoot(configuredRoot) {
            return configuredRoot
        }

        // This also supports running from the build bundle within the checkout.
        var url = URL(fileURLWithPath: Bundle.main.bundlePath)
        for _ in 0..<10 {
            if isKarenProjectRoot(url.path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }

        // Last-known default project location for older bundles.
        let volumeProject = NSHomeDirectory() + "/VolumeE/Karen"
        return isKarenProjectRoot(volumeProject) ? volumeProject : nil
    }

    private func isKarenProjectRoot(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/Package.swift") &&
        FileManager.default.fileExists(atPath: path + "/sidecar/karen_sidecar/__main__.py")
    }

    // MARK: - WebSocket

    private func openWebSocket() {
        guard !isStopped else { return }
        guard !isSocketReady, !isConnecting else { return }
        guard let url = socketURL else { return }
        isConnecting = true

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        guard let task = webSocketTask else { return }

        schedulePing()
        receiveMessages()
        task.send(.string("{\"type\":\"ping\"}")) { [weak self] error in
            if let error {
                print("[SidecarBridge] Startup ping failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.isConnecting = false
                }
            }
        }
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
                    self.isConnecting = false
                    self.isSocketReady = false
                    self.webSocketTask = nil
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
                let speechText = json["speech_text"] as? String ?? text
                self.onReply?(id, text, speechText, speak)
            case "error":
                let id  = json["id"]      as? String ?? ""
                let msg = json["message"] as? String ?? "Unknown error"
                self.onError?(id, msg)
            case "action":
                let id = json["id"] as? String ?? ""
                let skill = json["skill"] as? String ?? ""
                let payload = json["payload"] as? [String: Any] ?? [:]
                self.onAction?(id, skill, payload)
            case "pong":
                self.isConnecting = false
                self.isSocketReady = true
                break
            default:
                print("[SidecarBridge] Unknown message type: \(type)")
            }
        }
    }

    // MARK: - Send

    func sendTranscript(id: String, text: String, final isFinal: Bool,
                        source: String = "voice", imageLabels: [String] = []) async throws {
        let msg: [String: Any] = ["type": "transcript", "id": id, "text": text,
                                  "final": isFinal, "source": source,
                                  "image_labels": imageLabels]
        let data = try JSONSerialization.data(withJSONObject: msg)
        guard let str = String(data: data, encoding: .utf8) else { return }
        let task = try await waitForSocket()
        try await task.send(.string(str))
    }

    private func waitForSocket() async throws -> URLSessionWebSocketTask {
        for _ in 0..<50 {
            if isSocketReady, let task = webSocketTask, task.state == .running { return task }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BridgeError.notConnected
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

    func stop(completion: (() -> Void)? = nil) {
        isStopped = true
        pingTimer?.invalidate()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        isConnecting = false
        isSocketReady = false
        guard let process, process.isRunning else {
            completion?()
            return
        }
        process.terminationHandler = { _ in
            DispatchQueue.main.async { completion?() }
        }
        process.terminate()
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
