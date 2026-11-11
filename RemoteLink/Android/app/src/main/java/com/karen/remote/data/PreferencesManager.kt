package com.karen.remote.data

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.util.UUID

class PreferencesManager(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("karen_remote_prefs", Context.MODE_PRIVATE)
    private val gson = Gson()

    var serverUrl: String
        get() = prefs.getString("server_url", "https://karen-remotelink.karen-remote-tarun.workers.dev") ?: "https://karen-remotelink.karen-remote-tarun.workers.dev"
        set(value) = prefs.edit().putString("server_url", value.trimEnd('/')).apply()

    val deviceId: String
        get() {
            var id = prefs.getString("device_id", null)
            if (id == null) {
                id = UUID.randomUUID().toString()
                prefs.edit().putString("device_id", id).apply()
            }
            return id
        }

    var deviceName: String
        get() = prefs.getString("device_name", "${Build.MANUFACTURER.capitalize()} ${Build.MODEL}")
            ?: "Samsung Phone"
        set(value) = prefs.edit().putString("device_name", value).apply()

    var deviceToken: String?
        get() = prefs.getString("device_token", null)
        set(value) = prefs.edit().putString("device_token", value).apply()

    var macId: String?
        get() = prefs.getString("mac_id", null)
        set(value) = prefs.edit().putString("mac_id", value).apply()

    var macName: String?
        get() = prefs.getString("mac_name", null)
        set(value) = prefs.edit().putString("mac_name", value).apply()

    var isPaired: Boolean
        get() = prefs.getBoolean("is_paired", false) && deviceToken != null
        set(value) = prefs.edit().putBoolean("is_paired", value).apply()

    var fcmToken: String?
        get() = prefs.getString("fcm_token", null)
        set(value) = prefs.edit().putString("fcm_token", value).apply()

    fun savePairing(response: PairingResponse) {
        prefs.edit()
            .putString("device_token", response.deviceToken)
            .putString("mac_id", response.macId)
            .putString("mac_name", response.macName)
            .putBoolean("is_paired", true)
            .apply()
    }

    fun clearPairing() {
        prefs.edit()
            .remove("device_token")
            .remove("mac_id")
            .remove("mac_name")
            .putBoolean("is_paired", false)
            .apply()
    }

    fun getRequestHistory(): List<NotificationRequest> {
        val json = prefs.getString("request_history", null) ?: return emptyList()
        val type = object : TypeToken<List<NotificationRequest>>() {}.type
        return try {
            gson.fromJson(json, type) ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun saveRequestToHistory(req: NotificationRequest) {
        val current = getRequestHistory().toMutableList()
        val existingIndex = current.indexOfFirst { it.requestId == req.requestId }
        if (existingIndex >= 0) {
            current[existingIndex] = req
        } else {
            current.add(0, req)
        }
        val trimmed = current.take(50)
        prefs.edit().putString("request_history", gson.toJson(trimmed)).apply()
    }
}

