import Foundation

public final class RemoteLinkClient: @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var isWebSocketConnected: Bool = false
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Health & Info

    public func checkHealth() async throws -> ServerHealth {
        let url = baseURL.appendingPathComponent("/api/v1/health")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteLinkError.serverError("Health check failed")
        }
        return try decoder.decode(ServerHealth.self, from: data)
    }

    // MARK: - Pairing

    public func createPairingSession(macName: String = Host.current().localizedName ?? "My Mac") async throws -> PairingSessionResponse {
        let url = baseURL.appendingPathComponent("/api/v1/pairing/session")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "mac_id": UUID().uuidString,
            "mac_name": macName
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteLinkError.serverError("Failed to create pairing session")
        }
        return try decoder.decode(PairingSessionResponse.self, from: data)
    }

    public func pollPairingStatus(sessionId: String, timeoutSeconds: Double = 300) async throws -> PairingSessionResponse {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let url = baseURL.appendingPathComponent("/api/v1/pairing/status/\(sessionId)")

        while Date() < deadline {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let sessionResp = try decoder.decode(PairingSessionResponse.self, from: data)
                if sessionResp.isPaired {
                    return sessionResp
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        throw RemoteLinkError.timeout("Pairing session timed out waiting for phone.")
    }

    // MARK: - Device Management

    public func listDevices() async throws -> [DeviceRecord] {
        let url = baseURL.appendingPathComponent("/api/v1/devices")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteLinkError.serverError("Failed to list devices")
        }
        return try decoder.decode([DeviceRecord].self, from: data)
    }

    public func revokeDevice(deviceId: String) async throws -> Bool {
        let url = baseURL.appendingPathComponent("/api/v1/devices/\(deviceId)/revoke")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        return true
    }

    // MARK: - Notifications & Requests

    public func createNotification(
        type: String = "approval",
        title: String = "K.A.R.E.N. Request",
        message: String,
        details: String? = nil,
        actions: [String] = ["APPROVE", "DENY"],
        timeoutSeconds: Int = 120
    ) async throws -> NotificationRequestRecord {
        let url = baseURL.appendingPathComponent("/api/v1/requests")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "request_id": UUID().uuidString,
            "type": type,
            "title": title,
            "message": message,
            "actions": actions,
            "timeout_seconds": timeoutSeconds
        ]
        if let details = details { payload["details"] = details }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw RemoteLinkError.serverError(errorText)
        }
        return try decoder.decode(NotificationRequestRecord.self, from: data)
    }

    public func getRequest(requestId: String) async throws -> NotificationRequestRecord {
        let url = baseURL.appendingPathComponent("/api/v1/requests/\(requestId)")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteLinkError.notFound("Request \(requestId) not found")
        }
        return try decoder.decode(NotificationRequestRecord.self, from: data)
    }

    public func getPendingRequests() async throws -> [NotificationRequestRecord] {
        let url = baseURL.appendingPathComponent("/api/v1/requests/pending")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteLinkError.serverError("Failed to fetch pending requests")
        }
        return try decoder.decode([NotificationRequestRecord].self, from: data)
    }

    public func cancelRequest(requestId: String) async throws -> NotificationRequestRecord {
        let url = baseURL.appendingPathComponent("/api/v1/requests/\(requestId)/cancel")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Failed to cancel request"
            throw RemoteLinkError.serverError(errorText)
        }
        return try decoder.decode(NotificationRequestRecord.self, from: data)
    }

    /// Asynchronously waits for a request to be responded to, delivered, or expired.
    /// Non-blocking, supporting multiple concurrent pending requests.
    public func waitForResponse(
        requestId: String,
        timeoutSeconds: Int = 120,
        pollIntervalSeconds: Double = 0.5,
        onStatusUpdate: (@Sendable (NotificationRequestRecord) -> Void)? = nil
    ) async throws -> NotificationRequestRecord {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        var lastStatus: RequestStatus?

        while Date() < deadline {
            let record = try await getRequest(requestId: requestId)
            if record.status != lastStatus {
                lastStatus = record.status
                onStatusUpdate?(record)
            }

            if record.status == .responded || record.status == .expired || record.status == .cancelled {
                return record
            }

            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }

        // Return latest status even if timed out locally
        let record = try await getRequest(requestId: requestId)
        onStatusUpdate?(record)
        return record
    }

    // MARK: - WebSocket Stream

    public func startEventStream(onEvent: @escaping @Sendable (String, [String: Any]) -> Void) {
        var wsURLComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!
        wsURLComponents.scheme = (wsURLComponents.scheme == "https") ? "wss" : "ws"
        wsURLComponents.path = "/api/v1/ws/mac"

        guard let wsURL = wsURLComponents.url else { return }
        let wsTask = session.webSocketTask(with: wsURL)
        self.webSocketTask = wsTask
        wsTask.resume()
        self.isWebSocketConnected = true

        receiveNextMessage(onEvent: onEvent)
    }

    private func receiveNextMessage(onEvent: @escaping @Sendable (String, [String: Any]) -> Void) {
        webSocketTask?.receive { [weak self] result in
            guard let self, self.isWebSocketConnected else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let event = json["event"] as? String ?? "unknown"
                    let payload = json["payload"] as? [String: Any] ?? json
                    onEvent(event, payload)
                }
                self.receiveNextMessage(onEvent: onEvent)
            case .failure(let error):
                print("[RemoteLinkClient] WebSocket error: \(error.localizedDescription) - reconnecting in 2s")
                self.isWebSocketConnected = false
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    self.startEventStream(onEvent: onEvent)
                }
            }
        }
    }

    public func closeWebSocket() {
        isWebSocketConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }
}

public enum RemoteLinkError: LocalizedError, Sendable {
    case serverError(String)
    case notFound(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .serverError(let msg): return "Server Error: \(msg)"
        case .notFound(let msg): return "Not Found: \(msg)"
        case .timeout(let msg): return "Timeout: \(msg)"
        }
    }
}

