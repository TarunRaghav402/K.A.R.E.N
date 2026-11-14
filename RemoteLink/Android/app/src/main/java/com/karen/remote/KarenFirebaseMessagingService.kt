package com.karen.remote

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.karen.remote.data.NotificationRequest
import com.karen.remote.data.PreferencesManager
import com.karen.remote.data.RemoteLinkApi
import com.karen.remote.data.RequestStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class KarenFirebaseMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        val prefs = PreferencesManager(this)
        prefs.fcmToken = token
        if (prefs.isPaired) {
            val api = RemoteLinkApi(prefs)
            CoroutineScope(Dispatchers.IO).launch {
                api.updateFCMToken(token)
            }
        }
    }

    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        super.onMessageReceived(remoteMessage)

        val data = remoteMessage.data
        if (data.isEmpty()) return

        val requestId = data["request_id"] ?: return
        val type = data["type"] ?: "approval"
        val title = data["title"] ?: remoteMessage.notification?.title ?: "K.A.R.E.N. Request"
        val message = data["message"] ?: remoteMessage.notification?.body ?: "Waiting for your decision."
        val details = data["details"]
        val actionsJson = data["actions"] ?: "[\"APPROVE\", \"DENY\"]"
        val actionsList: List<String> = try {
            val listType = object : TypeToken<List<String>>() {}.type
            Gson().fromJson(actionsJson, listType) ?: listOf("APPROVE", "DENY")
        } catch (e: Exception) {
            listOf("APPROVE", "DENY")
        }
        val expiresAt = data["expires_at"]?.toDoubleOrNull() ?: (System.currentTimeMillis() / 1000.0 + 120)

        val req = NotificationRequest(
            requestId = requestId,
            type = type,
            title = title,
            message = message,
            details = details,
            actions = actionsList,
            status = RequestStatus.DELIVERED,
            createdAt = System.currentTimeMillis() / 1000.0,
            expiresAt = expiresAt
        )

        val prefs = PreferencesManager(this)
        prefs.saveRequestToHistory(req)

        // Acknowledge delivery
        val api = RemoteLinkApi(prefs)
        CoroutineScope(Dispatchers.IO).launch {
            api.acknowledgeDelivery(requestId)
        }

        showInteractiveNotification(this, req)
    }

    companion object {
        fun showInteractiveNotification(context: Context, req: NotificationRequest) {
            val notifManager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val notifId = req.requestId.hashCode()

            // Open MainActivity on notification tap
            val contentIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("request_id", req.requestId)
            }
            val contentPendingIntent = PendingIntent.getActivity(
                context,
                notifId,
                contentIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val largeIconBitmap = try {
                BitmapFactory.decodeResource(context.resources, R.mipmap.ic_launcher)
            } catch (e: Exception) {
                null
            }

            val builder = NotificationCompat.Builder(context, KarenApp.CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_karen_orb)
                .apply {
                    if (largeIconBitmap != null) {
                        setLargeIcon(largeIconBitmap)
                    }
                }
                .setContentTitle(req.title)
                .setContentText(req.message)
                .setStyle(NotificationCompat.BigTextStyle().bigText("${req.message}\n${req.details.orEmpty()}".trim()))
                .setContentIntent(contentPendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setVibrate(longArrayOf(0, 300, 150, 300))
                .setColor(0xFF00E5FF.toInt())

            // Add interactive action buttons based on available actions
            for ((index, action) in req.actions.withIndex()) {
                val actionUpper = action.uppercase()
                if (actionUpper == "REPLY") {
                    // Inline Direct Reply with RemoteInput
                    val remoteInput = RemoteInput.Builder(NotificationActionReceiver.KEY_REPLY_TEXT)
                        .setLabel("Type your reply…")
                        .build()

                    val replyIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                        setAction(NotificationActionReceiver.ACTION_NOTIFICATION_RESPONSE)
                        putExtra(NotificationActionReceiver.EXTRA_REQUEST_ID, req.requestId)
                        putExtra(NotificationActionReceiver.EXTRA_OUTCOME, "REPLY")
                    }
                    val replyPendingIntent = PendingIntent.getBroadcast(
                        context,
                        notifId * 10 + index,
                        replyIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                    )

                    val replyAction = NotificationCompat.Action.Builder(
                        android.R.drawable.ic_menu_send,
                        "REPLY",
                        replyPendingIntent
                    ).addRemoteInput(remoteInput).build()

                    builder.addAction(replyAction)
                } else {
                    // Standard action button (APPROVE, DENY, YES, NO)
                    val actionIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                        setAction(NotificationActionReceiver.ACTION_NOTIFICATION_RESPONSE)
                        putExtra(NotificationActionReceiver.EXTRA_REQUEST_ID, req.requestId)
                        putExtra(NotificationActionReceiver.EXTRA_OUTCOME, actionUpper)
                    }
                    val actionPendingIntent = PendingIntent.getBroadcast(
                        context,
                        notifId * 10 + index,
                        actionIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )

                    val actionIcon = when (actionUpper) {
                        "APPROVE", "YES" -> android.R.drawable.checkbox_on_background
                        "DENY", "NO", "REJECT" -> android.R.drawable.ic_menu_close_clear_cancel
                        else -> android.R.drawable.ic_dialog_info
                    }

                    builder.addAction(actionIcon, actionUpper, actionPendingIntent)
                }
            }

            notifManager.notify(notifId, builder.build())
        }
    }
}
