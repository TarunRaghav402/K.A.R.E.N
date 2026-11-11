package com.karen.remote.data

import com.google.gson.annotations.SerializedName

enum class RequestStatus {
    CREATED, SENT, DELIVERED, WAITING, RESPONDED, EXPIRED, CANCELLED, DELIVERY_FAILED
}

enum class RequestOutcome {
    APPROVED, DENIED, REPLIED, EXPIRED, CANCELLED, DELIVERY_FAILED
}

data class PairingRequest(
    @SerializedName("pairing_code") val pairingCode: String,
    @SerializedName("device_id") val deviceId: String,
    @SerializedName("device_name") val deviceName: String,
    @SerializedName("fcm_token") val fcmToken: String? = null
)

data class PairingResponse(
    @SerializedName("success") val success: Boolean,
    @SerializedName("device_token") val deviceToken: String,
    @SerializedName("mac_id") val macId: String,
    @SerializedName("mac_name") val macName: String,
    @SerializedName("paired_at") val pairedAt: Double,
    @SerializedName("message") val message: String
)

data class NotificationRequest(
    @SerializedName("request_id") val requestId: String,
    @SerializedName("type") val type: String,
    @SerializedName("title") val title: String,
    @SerializedName("message") val message: String,
    @SerializedName("details") val details: String? = null,
    @SerializedName("actions") val actions: List<String> = listOf("APPROVE", "DENY"),
    @SerializedName("status") val status: RequestStatus,
    @SerializedName("created_at") val createdAt: Double,
    @SerializedName("sent_at") val sentAt: Double? = null,
    @SerializedName("delivered_at") val deliveredAt: Double? = null,
    @SerializedName("responded_at") val respondedAt: Double? = null,
    @SerializedName("expires_at") val expiresAt: Double,
    @SerializedName("outcome") val outcome: RequestOutcome? = null,
    @SerializedName("reply_text") val replyText: String? = null
)

data class ResponseSubmit(
    @SerializedName("outcome") val outcome: RequestOutcome,
    @SerializedName("reply_text") val replyText: String? = null,
    @SerializedName("device_id") val deviceId: String
)

data class DeliveryAck(
    @SerializedName("device_id") val deviceId: String
)

data class WebSocketEvent(
    @SerializedName("event") val event: String,
    @SerializedName("payload") val payload: Map<String, Any?>
)

