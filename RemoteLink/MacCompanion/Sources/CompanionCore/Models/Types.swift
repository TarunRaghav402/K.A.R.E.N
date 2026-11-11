import Foundation

public enum ConnectionState: String, Codable, Sendable {
    case connected = "Connected"
    case reconnecting = "Reconnecting"
    case offline = "Offline"
}

public enum RequestStatus: String, Codable, Sendable {
    case created = "CREATED"
    case stored = "STORED"
    case notified = "NOTIFIED"
    case waiting = "WAITING"
    case responded = "RESPONDED"
    case synced = "SYNCED"
    case completed = "COMPLETED"
    case expired = "EXPIRED"
    case cancelled = "CANCELLED"
    case deliveryFailed = "DELIVERY_FAILED"
}

public enum RequestOutcome: String, Codable, Sendable {
    case approved = "APPROVED"
    case denied = "DENIED"
    case replied = "REPLIED"
    case expired = "EXPIRED"
    case cancelled = "CANCELLED"
    case deliveryFailed = "DELIVERY_FAILED"
}

public struct NotificationRequestRecord: Codable, Sendable, Identifiable {
    public var id: String { requestId }
    public let requestId: String
    public let type: String
    public let title: String
    public let message: String
    public let details: String?
    public let actions: [String]
    public let status: RequestStatus
    public let createdAt: Double
    public let sentAt: Double?
    public let deliveredAt: Double?
    public let respondedAt: Double?
    public let expiresAt: Double
    public let outcome: RequestOutcome?
    public let replyText: String?
    public let responderDeviceId: String?
    public let idempotencyKey: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case type
        case title
        case message
        case details
        case actions
        case status
        case createdAt = "created_at"
        case sentAt = "sent_at"
        case deliveredAt = "delivered_at"
        case respondedAt = "responded_at"
        case expiresAt = "expires_at"
        case outcome
        case replyText = "reply_text"
        case responderDeviceId = "responder_device_id"
        case idempotencyKey = "idempotency_key"
    }

    public init(
        requestId: String,
        type: String = "ACTION_PROMPT",
        title: String,
        message: String,
        details: String? = nil,
        actions: [String] = ["APPROVE", "DENY", "REPLY"],
        status: RequestStatus = .created,
        createdAt: Double = Date().timeIntervalSince1970,
        sentAt: Double? = nil,
        deliveredAt: Double? = nil,
        respondedAt: Double? = nil,
        expiresAt: Double = Date().timeIntervalSince1970 + 300,
        outcome: RequestOutcome? = nil,
        replyText: String? = nil,
        responderDeviceId: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.requestId = requestId
        self.type = type
        self.title = title
        self.message = message
        self.details = details
        self.actions = actions
        self.status = status
        self.createdAt = createdAt
        self.sentAt = sentAt
        self.deliveredAt = deliveredAt
        self.respondedAt = respondedAt
        self.expiresAt = expiresAt
        self.outcome = outcome
        self.replyText = replyText
        self.responderDeviceId = responderDeviceId
        self.idempotencyKey = idempotencyKey
    }
}

public struct DeviceRecord: Codable, Sendable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let pairedAt: Double?
    public let lastSeenAt: Double
    public let revoked: Bool?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case pairedAt = "paired_at"
        case lastSeenAt = "last_seen_at"
        case revoked
    }
}

public struct SyncSnapshot: Codable, Sendable {
    public let pendingRequests: [NotificationRequestRecord]
    public let unprocessedResponses: [NotificationRequestRecord]
    public let pairedDevices: [DeviceRecord]?
    public let devices: [DeviceRecord]?
    public let serverTime: Double

    public var effectiveDevices: [DeviceRecord] {
        pairedDevices ?? devices ?? []
    }

    enum CodingKeys: String, CodingKey {
        case pendingRequests = "pending_requests"
        case unprocessedResponses = "unprocessed_responses"
        case pairedDevices = "paired_devices"
        case devices
        case serverTime = "server_time"
    }
}

public struct ServerHealth: Codable, Sendable {
    public let status: String
    public let service: String
    public let pairedDevicesCount: Int?
    public let durableStorage: String?
    public let fcmConfigured: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case service
        case pairedDevicesCount = "paired_devices_count"
        case durableStorage = "durable_storage"
        case fcmConfigured = "fcm_configured"
    }
}

public struct PairingSessionRecord: Codable, Sendable {
    public let sessionId: String
    public let pairingCode: String
    public let qrPayload: String
    public let macId: String
    public let macName: String
    public let expiresAt: Double
    public let isPaired: Bool
    public let pairedDeviceId: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case pairingCode = "pairing_code"
        case qrPayload = "qr_payload"
        case macId = "mac_id"
        case macName = "mac_name"
        case expiresAt = "expires_at"
        case isPaired = "is_paired"
        case pairedDeviceId = "paired_device_id"
    }
}

public struct JournalEntry: Codable, Sendable {
    public let timestamp: Double
    public let requestId: String
    public let title: String
    public let outcome: RequestOutcome
    public let replyText: String?
    public let responderDeviceId: String?

    public init(
        timestamp: Double = Date().timeIntervalSince1970,
        requestId: String,
        title: String,
        outcome: RequestOutcome,
        replyText: String? = nil,
        responderDeviceId: String? = nil
    ) {
        self.timestamp = timestamp
        self.requestId = requestId
        self.title = title
        self.outcome = outcome
        self.replyText = replyText
        self.responderDeviceId = responderDeviceId
    }
}

public struct CompanionConfig: Codable, Sendable {
    public var cloudURL: URL
    public var macId: String
    public var macName: String
    public var macApiKey: String?
    public var pairedDeviceId: String?
    public var pollIntervalSeconds: Double

    enum CodingKeys: String, CodingKey {
        case cloudURL = "cloud_url"
        case macId = "mac_id"
        case macName = "mac_name"
        case macApiKey = "mac_api_key"
        case pairedDeviceId = "paired_device_id"
        case pollIntervalSeconds = "poll_interval_seconds"
    }

    public init(
        cloudURL: URL = URL(string: "https://karen-remotelink.karen-remote-tarun.workers.dev")!,
        macId: String = UUID().uuidString,
        macName: String = Host.current().localizedName ?? "My Mac",
        macApiKey: String? = nil,
        pairedDeviceId: String? = nil,
        pollIntervalSeconds: Double = 15.0
    ) {
        self.cloudURL = cloudURL
        self.macId = macId
        self.macName = macName
        self.macApiKey = macApiKey
        self.pairedDeviceId = pairedDeviceId
        self.pollIntervalSeconds = pollIntervalSeconds
    }
}

