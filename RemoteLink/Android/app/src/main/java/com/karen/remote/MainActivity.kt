package com.karen.remote

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.karen.remote.data.*
import com.karen.remote.ui.theme.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

class MainActivity : ComponentActivity() {

    private lateinit var prefs: PreferencesManager
    private lateinit var api: RemoteLinkApi

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = PreferencesManager(this)
        api = RemoteLinkApi(prefs)

        setContent {
            KarenRemoteTheme {
                MainScreen(prefs = prefs, api = api)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(prefs: PreferencesManager, api: RemoteLinkApi) {
    val scope = rememberCoroutineScope()
    var isPaired by remember { mutableStateOf(prefs.isPaired) }
    var isConnected by remember { mutableStateOf(false) }
    var pendingRequests by remember { mutableStateOf<List<NotificationRequest>>(emptyList()) }
    var history by remember { mutableStateOf(prefs.getRequestHistory()) }
    var showSettings by remember { mutableStateOf(false) }
    var showReplyDialogFor by remember { mutableStateOf<NotificationRequest?>(null) }
    var replyInputText by remember { mutableStateOf("") }
    var isSubmitting by remember { mutableStateOf(false) }

    // Request notification permissions on Android 13+
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
        onResult = {}
    )

    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        com.google.firebase.messaging.FirebaseMessaging.getInstance().token
            .addOnCompleteListener { task ->
                if (task.isSuccessful) {
                    val token = task.result
                    if (!token.isNullOrBlank()) {
                        prefs.fcmToken = token
                        if (prefs.isPaired) {
                            scope.launch {
                                api.updateFCMToken(token)
                            }
                        }
                    }
                }
            }
    }

    // Refresh pending requests and WebSocket connection
    fun refreshData() {
        if (isPaired) {
            scope.launch {
                api.getPendingRequests().onSuccess { list ->
                    pendingRequests = list
                }
                history = prefs.getRequestHistory()
            }
        }
    }

    LaunchedEffect(isPaired) {
        if (isPaired) {
            refreshData()
            api.connectWebSocket(
                onEvent = { event, payload ->
                    scope.launch {
                        refreshData()
                    }
                },
                onStatusChange = { connected ->
                    isConnected = connected
                }
            )
        }
    }

    // Periodic poll for pending requests
    LaunchedEffect(Unit) {
        while (true) {
            delay(3000)
            if (isPaired) {
                refreshData()
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(12.dp)
                                .clip(CircleShape)
                                .background(if (isConnected) KarenCyan else KarenYellow)
                        )
                        Spacer(modifier = Modifier.width(10.dp))
                        Text(
                            "K.A.R.E.N. Remote",
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            color = KarenTextPrimary
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { showSettings = true }) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings", tint = KarenCyan)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = KarenDarkBg)
            )
        },
        containerColor = KarenDarkBg
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = 16.dp)
        ) {
            if (!isPaired) {
                PairingView(
                    prefs = prefs,
                    api = api,
                    onPaired = {
                        isPaired = true
                        refreshData()
                    }
                )
            } else {
                DashboardView(
                    prefs = prefs,
                    pendingRequests = pendingRequests,
                    history = history,
                    onRespond = { req, outcome, text ->
                        scope.launch {
                            isSubmitting = true
                            api.respond(req.requestId, outcome, text).onSuccess {
                                refreshData()
                            }
                            isSubmitting = false
                        }
                    },
                    onOpenReply = { req ->
                        showReplyDialogFor = req
                        replyInputText = ""
                    },
                    onUnpair = {
                        prefs.clearPairing()
                        api.disconnectWebSocket()
                        isPaired = false
                    }
                )
            }
        }
    }

    // Reply Dialog
    if (showReplyDialogFor != null) {
        val req = showReplyDialogFor!!
        AlertDialog(
            onDismissRequest = { showReplyDialogFor = null },
            title = { Text("Reply to K.A.R.E.N.", color = KarenCyan, fontWeight = FontWeight.Bold) },
            text = {
                Column {
                    Text(req.message, color = KarenTextPrimary, fontSize = 14.sp)
                    Spacer(modifier = Modifier.height(12.dp))
                    OutlinedTextField(
                        value = replyInputText,
                        onValueChange = { replyInputText = it },
                        label = { Text("Your response") },
                        modifier = Modifier.fillMaxWidth(),
                        maxLines = 4,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = KarenCyan,
                            unfocusedBorderColor = KarenIndigo,
                            focusedTextColor = KarenTextPrimary,
                            unfocusedTextColor = KarenTextPrimary
                        )
                    )
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val text = replyInputText.trim()
                        showReplyDialogFor = null
                        if (text.isNotEmpty()) {
                            scope.launch {
                                api.respond(req.requestId, RequestOutcome.REPLIED, text).onSuccess {
                                    refreshData()
                                }
                            }
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = KarenCyan)
                ) {
                    Text("Send Reply", color = KarenDarkBg, fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showReplyDialogFor = null }) {
                    Text("Cancel", color = KarenTextSecondary)
                }
            },
            containerColor = KarenSurface
        )
    }

    // Settings Sheet
    if (showSettings) {
        ModalBottomSheet(
            onDismissRequest = { showSettings = false },
            containerColor = KarenSurface
        ) {
            SettingsSheet(
                prefs = prefs,
                onSave = { newUrl ->
                    prefs.serverUrl = newUrl
                    showSettings = false
                    if (isPaired) {
                        api.disconnectWebSocket()
                        refreshData()
                    }
                }
            )
        }
    }
}

@Composable
fun PairingView(prefs: PreferencesManager, api: RemoteLinkApi, onPaired: () -> Unit) {
    var pairingCode by remember { mutableStateOf("") }
    var serverUrl by remember { mutableStateOf(prefs.serverUrl) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 24.dp),
        colors = CardDefaults.cardColors(containerColor = KarenSurface),
        shape = RoundedCornerShape(16.dp)
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(CircleShape)
                    .background(KarenCyanDim)
                    .border(2.dp, KarenCyan, CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Icon(Icons.Default.PhoneIphone, contentDescription = null, tint = KarenCyan, modifier = Modifier.size(32.dp))
            }

            Spacer(modifier = Modifier.height(16.dp))
            Text("Pair with K.A.R.E.N.", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = KarenTextPrimary)
            Text(
                "Enter the 6-character code shown on your Mac's K.A.R.E.N. Remote Link controller.",
                fontSize = 13.sp,
                color = KarenTextSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 6.dp, bottom = 18.dp)
            )

            OutlinedTextField(
                value = serverUrl,
                onValueChange = { serverUrl = it },
                label = { Text("Relay Server URL") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = KarenCyan,
                    unfocusedBorderColor = KarenIndigo,
                    focusedTextColor = KarenTextPrimary,
                    unfocusedTextColor = KarenTextPrimary
                )
            )

            Spacer(modifier = Modifier.height(12.dp))

            OutlinedTextField(
                value = pairingCode,
                onValueChange = { if (it.length <= 6) pairingCode = it.uppercase() },
                label = { Text("6-Character Pairing Code") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                textStyle = LocalTextStyle.current.copy(
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 4.sp,
                    textAlign = TextAlign.Center
                ),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = KarenCyan,
                    unfocusedBorderColor = KarenIndigo,
                    focusedTextColor = KarenCyan,
                    unfocusedTextColor = KarenCyan
                )
            )

            if (errorMessage != null) {
                Spacer(modifier = Modifier.height(10.dp))
                Text(errorMessage!!, color = KarenRed, fontSize = 13.sp)
            }

            Spacer(modifier = Modifier.height(20.dp))

            Button(
                onClick = {
                    if (pairingCode.length != 6) {
                        errorMessage = "Please enter the full 6-character code."
                        return@Button
                    }
                    prefs.serverUrl = serverUrl
                    isLoading = true
                    errorMessage = null
                    scope.launch {
                        api.pair(pairingCode).fold(
                            onSuccess = {
                                isLoading = false
                                onPaired()
                            },
                            onFailure = { err ->
                                isLoading = false
                                errorMessage = err.message ?: "Pairing failed. Check server URL and code."
                            }
                        )
                    }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
                colors = ButtonDefaults.buttonColors(containerColor = KarenCyan),
                enabled = !isLoading
            ) {
                if (isLoading) {
                    CircularProgressIndicator(color = KarenDarkBg, modifier = Modifier.size(24.dp))
                } else {
                    Text("Connect & Pair Device", color = KarenDarkBg, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                }
            }
        }
    }
}

@Composable
fun DashboardView(
    prefs: PreferencesManager,
    pendingRequests: List<NotificationRequest>,
    history: List<NotificationRequest>,
    onRespond: (NotificationRequest, RequestOutcome, String?) -> Unit,
    onOpenReply: (NotificationRequest) -> Unit,
    onUnpair: () -> Unit
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Paired Mac Card
        item {
            Card(
                colors = CardDefaults.cardColors(containerColor = KarenSurface),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.LaptopMac, contentDescription = null, tint = KarenCyan)
                        Spacer(modifier = Modifier.width(10.dp))
                        Column {
                            Text(prefs.macName ?: "Paired Mac", fontWeight = FontWeight.Bold, color = KarenTextPrimary, fontSize = 15.sp)
                            Text("Ready for notifications", color = KarenGreen, fontSize = 12.sp)
                        }
                    }
                    TextButton(onClick = onUnpair) {
                        Text("Disconnect", color = KarenRed, fontSize = 12.sp)
                    }
                }
            }
        }

        // Active Pending Requests
        if (pendingRequests.isNotEmpty()) {
            item {
                Text("PENDING REQUESTS (${pendingRequests.size})", fontWeight = FontWeight.Bold, color = KarenCyan, fontSize = 13.sp)
            }
            items(pendingRequests, key = { it.requestId }) { req ->
                PendingRequestCard(
                    req = req,
                    onRespond = onRespond,
                    onOpenReply = onOpenReply
                )
            }
        } else {
            item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = KarenSurfaceVariant.copy(alpha = 0.5f)),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(20.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Icon(Icons.Default.NotificationsNone, contentDescription = null, tint = KarenTextSecondary, modifier = Modifier.size(32.dp))
                        Spacer(modifier = Modifier.height(8.dp))
                        Text("No Pending Requests", color = KarenTextSecondary, fontSize = 14.sp)
                        Text("Notifications sent from your Mac will appear here.", color = KarenTextSecondary.copy(alpha = 0.7f), fontSize = 12.sp)
                    }
                }
            }
        }

        // History Section
        item {
            Text("NOTIFICATION HISTORY", fontWeight = FontWeight.Bold, color = KarenTextSecondary, fontSize = 13.sp)
        }

        if (history.isEmpty()) {
            item {
                Text("No previous requests recorded.", color = KarenTextSecondary.copy(alpha = 0.5f), fontSize = 13.sp)
            }
        } else {
            items(history, key = { it.requestId }) { req ->
                HistoryItem(req)
            }
        }

        item {
            Spacer(modifier = Modifier.height(20.dp))
        }
    }
}

@Composable
fun PendingRequestCard(
    req: NotificationRequest,
    onRespond: (NotificationRequest, RequestOutcome, String?) -> Unit,
    onOpenReply: (NotificationRequest) -> Unit
) {
    var remainingSeconds by remember { mutableStateOf(maxOf(0, (req.expiresAt - System.currentTimeMillis() / 1000).toInt())) }

    LaunchedEffect(req.expiresAt) {
        while (remainingSeconds > 0) {
            delay(1000)
            remainingSeconds = maxOf(0, (req.expiresAt - System.currentTimeMillis() / 1000).toInt())
        }
    }

    Card(
        colors = CardDefaults.cardColors(containerColor = KarenSurface),
        shape = RoundedCornerShape(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, KarenCyan.copy(alpha = 0.5f), RoundedCornerShape(14.dp))
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(req.title, fontWeight = FontWeight.Bold, color = KarenCyan, fontSize = 16.sp)
                Badge(containerColor = if (remainingSeconds > 10) KarenSurfaceVariant else KarenRed) {
                    Text("${remainingSeconds}s", color = KarenTextPrimary, fontSize = 11.sp)
                }
            }

            Spacer(modifier = Modifier.height(8.dp))
            Text(req.message, color = KarenTextPrimary, fontSize = 14.sp)

            if (!req.details.isNullOrEmpty()) {
                Spacer(modifier = Modifier.height(4.dp))
                Text(req.details, color = KarenTextSecondary, fontSize = 12.sp)
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Action Buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                for (action in req.actions) {
                    when (action.uppercase()) {
                        "APPROVE", "YES" -> {
                            Button(
                                onClick = { onRespond(req, RequestOutcome.APPROVED, null) },
                                colors = ButtonDefaults.buttonColors(containerColor = KarenGreen),
                                modifier = Modifier.weight(1f)
                            ) {
                                Text(action, color = KarenDarkBg, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                            }
                        }
                        "DENY", "NO" -> {
                            Button(
                                onClick = { onRespond(req, RequestOutcome.DENIED, null) },
                                colors = ButtonDefaults.buttonColors(containerColor = KarenRed),
                                modifier = Modifier.weight(1f)
                            ) {
                                Text(action, color = KarenTextPrimary, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                            }
                        }
                        "REPLY" -> {
                            Button(
                                onClick = { onOpenReply(req) },
                                colors = ButtonDefaults.buttonColors(containerColor = KarenCyan),
                                modifier = Modifier.weight(1f)
                            ) {
                                Text("REPLY", color = KarenDarkBg, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                            }
                        }
                        else -> {
                            Button(
                                onClick = { onRespond(req, RequestOutcome.APPROVED, null) },
                                colors = ButtonDefaults.buttonColors(containerColor = KarenIndigo),
                                modifier = Modifier.weight(1f)
                            ) {
                                Text(action, color = KarenTextPrimary, fontSize = 13.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun HistoryItem(req: NotificationRequest) {
    Card(
        colors = CardDefaults.cardColors(containerColor = KarenSurface.copy(alpha = 0.7f)),
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(req.title, fontWeight = FontWeight.SemiBold, color = KarenTextPrimary, fontSize = 14.sp)
                OutcomeBadge(req.outcome ?: if (req.status == RequestStatus.EXPIRED) RequestOutcome.EXPIRED else null)
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(req.message, color = KarenTextSecondary, fontSize = 13.sp)

            if (!req.replyText.isNullOrEmpty()) {
                Spacer(modifier = Modifier.height(4.dp))
                Text("Reply: \"${req.replyText}\"", color = KarenCyan, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

@Composable
fun OutcomeBadge(outcome: RequestOutcome?) {
    val (text, color) = when (outcome) {
        RequestOutcome.APPROVED -> "Approved" to KarenGreen
        RequestOutcome.DENIED -> "Denied" to KarenRed
        RequestOutcome.REPLIED -> "Replied" to KarenCyan
        RequestOutcome.EXPIRED -> "Expired" to KarenYellow
        RequestOutcome.CANCELLED -> "Cancelled" to KarenTextSecondary
        RequestOutcome.DELIVERY_FAILED -> "Failed" to KarenRed
        null -> "Pending" to KarenIndigo
    }

    Surface(
        color = color.copy(alpha = 0.2f),
        shape = RoundedCornerShape(6.dp)
    ) {
        Text(
            text = text,
            color = color,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
        )
    }
}

@Composable
fun SettingsSheet(prefs: PreferencesManager, onSave: (String) -> Unit) {
    var url by remember { mutableStateOf(prefs.serverUrl) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(24.dp)
    ) {
        Text("Remote Link Settings", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = KarenCyan)
        Spacer(modifier = Modifier.height(16.dp))

        OutlinedTextField(
            value = url,
            onValueChange = { url = it },
            label = { Text("Relay Server URL") },
            modifier = Modifier.fillMaxWidth(),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = KarenCyan,
                unfocusedBorderColor = KarenIndigo,
                focusedTextColor = KarenTextPrimary,
                unfocusedTextColor = KarenTextPrimary
            )
        )

        Spacer(modifier = Modifier.height(12.dp))
        Text("Device ID: ${prefs.deviceId}", color = KarenTextSecondary, fontSize = 11.sp)
        Text("FCM Token: ${prefs.fcmToken?.take(16) ?: "Not registered"}...", color = KarenTextSecondary, fontSize = 11.sp)

        Spacer(modifier = Modifier.height(16.dp))
        Card(
            colors = CardDefaults.cardColors(containerColor = KarenSurface),
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier
                .fillMaxWidth()
                .border(1.dp, KarenCyan.copy(alpha = 0.3f), RoundedCornerShape(10.dp))
        ) {
            Column(modifier = Modifier.padding(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Info, contentDescription = null, tint = KarenCyan, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Samsung Background Delivery", fontWeight = FontWeight.SemiBold, color = KarenCyan, fontSize = 12.sp)
                }
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    "To ensure instant notifications when your phone is locked or screen is off:\n" +
                    "1. Go to Settings > Apps > K.A.R.E.N. Remote\n" +
                    "2. Tap Battery > Select 'Unrestricted'\n" +
                    "3. In Device Care, exclude K.A.R.E.N. from 'Sleeping apps'",
                    color = KarenTextSecondary,
                    fontSize = 11.sp,
                    lineHeight = 16.sp
                )
            }
        }

        Spacer(modifier = Modifier.height(20.dp))
        Button(
            onClick = { onSave(url) },
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = KarenCyan)
        ) {
            Text("Save Settings", color = KarenDarkBg, fontWeight = FontWeight.Bold)
        }
        Spacer(modifier = Modifier.height(20.dp))
    }
}

