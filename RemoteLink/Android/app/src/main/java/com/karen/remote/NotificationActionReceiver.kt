package com.karen.remote

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import com.karen.remote.data.PreferencesManager
import com.karen.remote.data.RemoteLinkApi
import com.karen.remote.data.RequestOutcome
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class NotificationActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_NOTIFICATION_RESPONSE = "com.karen.remote.ACTION_NOTIFICATION_RESPONSE"
        const val EXTRA_REQUEST_ID = "extra_request_id"
        const val EXTRA_OUTCOME = "extra_outcome"
        const val KEY_REPLY_TEXT = "reply_text"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return
        val outcomeStr = intent.getStringExtra(EXTRA_OUTCOME)

        // Check for inline RemoteInput reply
        val remoteInputBundle = RemoteInput.getResultsFromIntent(intent)
        val inlineReplyText = remoteInputBundle?.getCharSequence(KEY_REPLY_TEXT)?.toString()

        val outcome: RequestOutcome = when {
            inlineReplyText != null -> RequestOutcome.REPLIED
            outcomeStr == "APPROVE" || outcomeStr == "YES" -> RequestOutcome.APPROVED
            outcomeStr == "DENY" || outcomeStr == "NO" || outcomeStr == "REJECT" || outcomeStr == "REJECTED" -> RequestOutcome.DENIED
            outcomeStr == "REPLY" -> RequestOutcome.REPLIED
            else -> RequestOutcome.DENIED
        }

        val prefs = PreferencesManager(context)
        val api = RemoteLinkApi(prefs)

        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notifId = requestId.hashCode()

        // Update notification immediately to indicate decision has been dispatched
        val statusText = when (outcome) {
            RequestOutcome.APPROVED -> "✓ Approved by phone"
            RequestOutcome.DENIED -> "✗ Denied by phone"
            RequestOutcome.REPLIED -> "💬 Reply sent: \"${inlineReplyText.orEmpty()}\""
            else -> "Decision dispatched"
        }

        val updatedNotification = NotificationCompat.Builder(context, KarenApp.CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_karen_orb)
            .setContentTitle("K.A.R.E.N. Response")
            .setContentText(statusText)
            .setAutoCancel(true)
            .setTimeoutAfter(4000)
            .build()

        notificationManager.notify(notifId, updatedNotification)

        // Send to Mac via backend relay
        CoroutineScope(Dispatchers.IO).launch {
            try {
                api.respond(
                    requestId = requestId,
                    outcome = outcome,
                    replyText = inlineReplyText
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}

