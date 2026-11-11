package com.karen.remote.data

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

class RemoteLinkApi(private val prefs: PreferencesManager) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build()
    private val gson = Gson()
    private val jsonMedia = "application/json; charset=utf-8".toMediaType()
    private var webSocket: WebSocket? = null

    suspend fun pair(pairingCode: String): Result<PairingResponse> = withContext(Dispatchers.IO) {
        try {
            val url = "${prefs.serverUrl}/api/v1/pairing/pair"
            val reqBody = PairingRequest(
                pairingCode = pairingCode.trim().uppercase(),
                deviceId = prefs.deviceId,
                deviceName = prefs.deviceName,
                fcmToken = prefs.fcmToken
            )
            val json = gson.toJson(reqBody)
            val request = Request.Builder()
                .url(url)
                .post(json.toRequestBody(jsonMedia))
                .build()

            client.newCall(request).execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                if (resp.isSuccessful) {
                    val result = gson.fromJson(body, PairingResponse::class.java)
                    prefs.savePairing(result)
                    Result.success(result)
                } else {
                    Result.failure(Exception("Pairing failed (${resp.code}): $body"))
                }
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun acknowledgeDelivery(requestId: String): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val token = prefs.deviceToken ?: return@withContext Result.failure(Exception("Not paired"))
            val url = "${prefs.serverUrl}/api/v1/requests/$requestId/delivered"
            val reqBody = DeliveryAck(deviceId = prefs.deviceId)
            val request = Request.Builder()
                .url(url)
                .addHeader("Authorization", "Bearer $token")
                .addHeader("X-Device-ID", prefs.deviceId)
                .post(gson.toJson(reqBody).toRequestBody(jsonMedia))
                .build()

            client.newCall(request).execute().use { resp ->
                Result.success(resp.isSuccessful)
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun respond(
        requestId: String,
        outcome: RequestOutcome,
        replyText: String? = null
    ): Result<NotificationRequest> = withContext(Dispatchers.IO) {
        try {
            val token = prefs.deviceToken ?: return@withContext Result.failure(Exception("Not paired"))
            val url = "${prefs.serverUrl}/api/v1/requests/$requestId/respond"
            val reqBody = ResponseSubmit(
                outcome = outcome,
                replyText = replyText,
                deviceId = prefs.deviceId
            )
            val request = Request.Builder()
                .url(url)
                .addHeader("Authorization", "Bearer $token")
                .addHeader("X-Device-ID", prefs.deviceId)
                .post(gson.toJson(reqBody).toRequestBody(jsonMedia))
                .build()

            client.newCall(request).execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                if (resp.isSuccessful) {
                    val updated = gson.fromJson(body, NotificationRequest::class.java)
                    prefs.saveRequestToHistory(updated)
                    Result.success(updated)
                } else {
                    Result.failure(Exception("Response error (${resp.code}): $body"))
                }
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getPendingRequests(): Result<List<NotificationRequest>> = withContext(Dispatchers.IO) {
        try {
            val url = "${prefs.serverUrl}/api/v1/requests/pending"
            val request = Request.Builder().url(url).get().build()
            client.newCall(request).execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                if (resp.isSuccessful) {
                    val type = object : TypeToken<List<NotificationRequest>>() {}.type
                    val list = gson.fromJson<List<NotificationRequest>>(body, type) ?: emptyList()
                    Result.success(list)
                } else {
                    Result.failure(Exception("Failed to fetch pending requests: ${resp.code}"))
                }
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun updateFCMToken(fcmToken: String): Result<Boolean> = withContext(Dispatchers.IO) {
        try {
            val token = prefs.deviceToken ?: return@withContext Result.failure(Exception("Not paired"))
            val url = "${prefs.serverUrl}/api/v1/devices/fcm"
            val map = mapOf("fcm_token" to fcmToken)
            val request = Request.Builder()
                .url(url)
                .addHeader("Authorization", "Bearer $token")
                .addHeader("X-Device-ID", prefs.deviceId)
                .post(gson.toJson(map).toRequestBody(jsonMedia))
                .build()

            client.newCall(request).execute().use { resp ->
                Result.success(resp.isSuccessful)
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun connectWebSocket(
        onEvent: (String, Map<String, Any?>) -> Unit,
        onStatusChange: (Boolean) -> Unit
    ) {
        val token = prefs.deviceToken ?: return
        val wsUrl = prefs.serverUrl.replace("http://", "ws://").replace("https://", "wss://") +
                "/api/v1/ws/phone?device_id=${prefs.deviceId}&token=$token"

        val request = Request.Builder().url(wsUrl).build()
        webSocket?.close(1000, "Reconnecting")
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                onStatusChange(true)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val type = object : TypeToken<Map<String, Any?>>() {}.type
                    val map: Map<String, Any?> = gson.fromJson(text, type) ?: return
                    val event = map["event"] as? String ?: "unknown"
                    val payload = (map["payload"] as? Map<String, Any?>) ?: map
                    onEvent(event, payload)
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                onStatusChange(false)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                onStatusChange(false)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                onStatusChange(false)
            }
        })
    }

    fun disconnectWebSocket() {
        webSocket?.close(1000, "App paused")
        webSocket = null
    }
}

