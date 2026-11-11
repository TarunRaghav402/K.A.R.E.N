import Foundation

public enum CloudAPIError: Error, LocalizedError, Sendable {
    case invalidURL
    case networkError(String)
    case serverError(Int, String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Cloud API URL"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .serverError(let code, let msg):
            return "Server returned \(code): \(msg)"
        case .decodingError(let msg):
            return "Decoding error: \(msg)"
        }
    }
}

public final class CloudAPIClient: @unchecked Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 30.0
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    private func applyHeaders(to request: inout URLRequest, config: CompanionConfig) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.macId, forHTTPHeaderField: "X-Mac-ID")
        if let key = config.macApiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    public func createPairingSession(config: CompanionConfig) async throws -> PairingSessionRecord {
        let endpoint = config.cloudURL.appendingPathComponent("api/v1/pairing/session")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        applyHeaders(to: &request, config: config)

        let payload: [String: Any] = [
            "mac_id": config.macId,
            "mac_name": config.macName
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudAPIError.serverError(http.statusCode, body)
        }
        return try decoder.decode(PairingSessionRecord.self, from: data)
    }

    public func checkHealth(config: CompanionConfig) async throws -> ServerHealth {
        let endpoint = config.cloudURL.appendingPathComponent("api/v1/health")
        var request = URLRequest(url: endpoint)
        applyHeaders(to: &request, config: config)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudAPIError.serverError(http.statusCode, body)
        }
        return try decoder.decode(ServerHealth.self, from: data)
    }

    public func fetchSyncSnapshot(config: CompanionConfig) async throws -> SyncSnapshot {
        let endpoint = config.cloudURL.appendingPathComponent("api/v1/sync")
        var request = URLRequest(url: endpoint)
        applyHeaders(to: &request, config: config)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudAPIError.serverError(http.statusCode, body)
        }
        return try decoder.decode(SyncSnapshot.self, from: data)
    }

    public func sendNotificationRequest(
        config: CompanionConfig,
        title: String,
        message: String,
        details: String? = nil,
        actions: [String] = ["APPROVE", "DENY", "REPLY"],
        timeoutSeconds: Double = 300,
        idempotencyKey: String? = nil
    ) async throws -> NotificationRequestRecord {
        let endpoint = config.cloudURL.appendingPathComponent("api/v1/requests")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        applyHeaders(to: &request, config: config)

        var payload: [String: Any] = [
            "title": title,
            "message": message,
            "actions": actions,
            "timeout_seconds": timeoutSeconds
        ]
        if let details = details { payload["details"] = details }
        if let idempotencyKey = idempotencyKey { payload["idempotency_key"] = idempotencyKey }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError("Invalid response")
        }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudAPIError.serverError(http.statusCode, body)
        }
        return try decoder.decode(NotificationRequestRecord.self, from: data)
    }

    public func acknowledgeResponse(config: CompanionConfig, requestId: String) async throws {
        let endpoint = config.cloudURL.appendingPathComponent("api/v1/requests/\(requestId)/ack")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        applyHeaders(to: &request, config: config)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudAPIError.serverError(http.statusCode, body)
        }
    }

    public func cancelRequest(config: CompanionConfig, requestId: String) async throws {
        let endpoint = config.cloudURL.appendingPathComponent("api/v1/requests/\(requestId)/cancel")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        applyHeaders(to: &request, config: config)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError.networkError("Invalid response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CloudAPIError.serverError(http.statusCode, body)
        }
    }
}

