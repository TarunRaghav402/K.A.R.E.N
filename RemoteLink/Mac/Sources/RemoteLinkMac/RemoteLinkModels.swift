import Foundation

public enum RequestStatus: String, Codable, Sendable {
    case created = "CREATED"
    case sent = "SENT"
    case delivered = "DELIVERED"
    case waiting = "WAITING"
    case responded = "RESPONDED"
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

public struct PairingSessionResponse: Codable, Sendable {
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

public struct NotificationRequestRecord: Codable, Sendable {
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
    }
}

public struct DeviceRecord: Codable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public let pairedAt: Double
    public let lastSeenAt: Double
    public let revoked: Bool

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case pairedAt = "paired_at"
        case lastSeenAt = "last_seen_at"
        case revoked
    }
}

public struct ServerHealth: Codable, Sendable {
    public let status: String
    public let service: String
    public let pairedDevicesCount: Int
    public let connectedMacClients: Int
    public let connectedPhoneClients: Int
    public let fcmConfigured: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case service
        case pairedDevicesCount = "paired_devices_count"
        case connectedMacClients = "connected_mac_clients"
        case connectedPhoneClients = "connected_phone_clients"
        case fcmConfigured = "fcm_configured"
    }
}

