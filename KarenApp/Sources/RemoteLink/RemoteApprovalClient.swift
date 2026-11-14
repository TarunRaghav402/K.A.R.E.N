import Foundation

public enum RemoteApprovalResult: Sendable {
    case approved
    case rejected
    case expired
    case failed(String)
}

public final class RemoteApprovalClient: @unchecked Sendable {
    public static let shared = RemoteApprovalClient()

    private let session: URLSession
    private let defaultCloudURL = URL(string: "https://karen-remotelink.karen-remote-tarun.workers.dev")!
    private let defaultMacId = "E806C9E4-89BB-441F-A1C0-40CDB5DD92D1"
    private let configFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".karen")
        .appendingPathComponent("remote_link_cloud_config.json")

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 30.0
        self.session = URLSession(configuration: config)
    }

    private struct ConfigData: Codable {
        let cloud_url: String?
        let mac_id: String?
        let mac_api_key: String?
    }

    private func loadConfig() -> (url: URL, macId: String, apiKey: String?) {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(ConfigData.self, from: data) else {
            return (defaultCloudURL, defaultMacId, nil)
        }
        let url = config.cloud_url.flatMap { URL(string: $0) } ?? defaultCloudURL
        let macId = (config.mac_id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? config.mac_id! : defaultMacId
        return (url, macId, config.mac_api_key)
    }

    public func requestSettingsApproval(timeoutSeconds: Double = 86400.0) async -> RemoteApprovalResult {
        let (baseURL, macId, apiKey) = loadConfig()
        let endpoint = baseURL.appendingPathComponent("api/v1/requests")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(macId, forHTTPHeaderField: "X-Mac-ID")
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let idempotencyKey = UUID().uuidString
        let payload: [String: Any] = [
            "title": "K.A.R.E.N. Settings Access Request",
            "message": "The user wants to open K.A.R.E.N. Settings. Do you approve?",
            "details": "Requested via voice or HUD on Mac",
            "actions": ["APPROVE", "DENY"],
            "timeout_seconds": timeoutSeconds,
            "idempotency_key": idempotencyKey
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failed("Failed to serialize request payload")
        }
        request.httpBody = httpBody

        let requestId: String
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Invalid server response")
            }
            guard http.statusCode == 200 || http.statusCode == 201 else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                return .failed("HTTP \(http.statusCode): \(errBody)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rid = (json["request_id"] as? String) ?? (json["id"] as? String),
                  !rid.isEmpty else {
                return .failed("Missing request id in response")
            }
            requestId = rid
            NSLog("[RemoteApprovalClient] Dispatched approval request: %@", requestId)
        } catch {
            return .failed("Network error: \(error.localizedDescription)")
        }

        // Poll for outcome every 1.0 second until resolution or timeout
        let pollEndpoint = baseURL.appendingPathComponent("api/v1/requests/\(requestId)")
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            var pollReq = URLRequest(url: pollEndpoint)
            pollReq.httpMethod = "GET"
            pollReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            pollReq.setValue(macId, forHTTPHeaderField: "X-Mac-ID")
            if let key = apiKey, !key.isEmpty {
                pollReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }

            guard let (data, response) = try? await session.data(for: pollReq),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let status = (record["status"] as? String)?.uppercased() ?? ""
            let outcome = (record["outcome"] as? String)?.uppercased() ?? ""

            if outcome == "APPROVED" || outcome == "APPROVE" {
                NSLog("[RemoteApprovalClient] Request %@ APPROVED", requestId)
                await acknowledge(requestId: requestId, baseURL: baseURL, macId: macId, apiKey: apiKey)
                return .approved
            } else if outcome == "DENIED" || outcome == "REJECT" || outcome == "REJECTED" {
                NSLog("[RemoteApprovalClient] Request %@ REJECTED", requestId)
                await acknowledge(requestId: requestId, baseURL: baseURL, macId: macId, apiKey: apiKey)
                return .rejected
            }

            if status == "RESPONDED" || status == "COMPLETED" || status == "SYNCED" {
                await acknowledge(requestId: requestId, baseURL: baseURL, macId: macId, apiKey: apiKey)
                if outcome == "APPROVED" || outcome == "APPROVE" {
                    return .approved
                } else if outcome == "DENIED" || outcome == "REJECT" || outcome == "REJECTED" {
                    return .rejected
                }
            } else if status == "EXPIRED" {
                NSLog("[RemoteApprovalClient] Request %@ EXPIRED on server", requestId)
                return .expired
            } else if status == "CANCELLED" {
                NSLog("[RemoteApprovalClient] Request %@ CANCELLED", requestId)
                return .rejected
            }
        }

        NSLog("[RemoteApprovalClient] Request %@ timed out after %.0fs", requestId, timeoutSeconds)
        await cancel(requestId: requestId, baseURL: baseURL, macId: macId, apiKey: apiKey)
        return .expired
    }

    private func acknowledge(requestId: String, baseURL: URL, macId: String, apiKey: String?) async {
        let endpoint = baseURL.appendingPathComponent("api/v1/requests/\(requestId)/ack")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(macId, forHTTPHeaderField: "X-Mac-ID")
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await session.data(for: request)
    }

    private func cancel(requestId: String, baseURL: URL, macId: String, apiKey: String?) async {
        let endpoint = baseURL.appendingPathComponent("api/v1/requests/\(requestId)/cancel")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(macId, forHTTPHeaderField: "X-Mac-ID")
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await session.data(for: request)
    }
}
