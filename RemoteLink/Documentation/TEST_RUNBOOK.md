# K.A.R.E.N. Remote Link — Complete Testing Runbook

This runbook covers the end-to-end verification matrix for K.A.R.E.N. Remote Link across all 10 test scenarios.

---

## Pre-flight Checklist

1. **Start Backend Relay:**
   ```bash
   cd /Users/tarunraghav/VolumeE/karen
   PYTHONPATH=. sidecar/.venv/bin/python3 RemoteLink/Backend/run_server.py
   ```
2. **Verify Server Health:**
   ```bash
   curl http://127.0.0.1:8765/api/v1/health
   # Returns: {"status":"healthy","service":"karen-remotelink-relay",...}
   ```
3. **Launch Mac Test Controller:**
   ```bash
   cd /Users/tarunraghav/VolumeE/karen/RemoteLink/Mac
   swift run karen-remote-cli
   ```
4. **Install Android APK on Samsung Phone:**
   ```bash
   adb install -r RemoteLink/Android/app/build/outputs/apk/debug/app-debug.apk
   ```

---

## Test Execution Matrix

### Test 1 — Pairing
* **Objective:** Pair Mac with Android phone using a secure 6-character session code.
* **Steps:**
  1. In the Mac controller, select `[1]` to generate a pairing session.
  2. Note the 6-character code (e.g. `7K9P2X`).
  3. Open **K.A.R.E.N. Remote** on your Samsung phone.
  4. Ensure Relay Server URL is set to `http://<mac-ip>:8765` or your public tunnel URL.
  5. Enter the code and tap **Connect & Pair Device**.
* **Expected Result:**
  * Phone displays: "Paired with [Mac Name]".
  * Mac controller outputs: `✓ SUCCESS: Device successfully paired with K.A.R.E.N.!`.
* **Automated Test Coverage:** `test_pairing_lifecycle_and_authentication` in `RemoteLink/Tests/test_backend.py` (PASSED).

---

### Test 2 — Notification Delivery
* **Objective:** Send a notification from Mac and verify it appears on the phone.
* **Steps:**
  1. In the Mac controller, select `[2]` (Send Type A: Approval Notification).
  2. Status transitions: `[CREATED]` -> `[SENT]`.
* **Expected Result:**
  * Phone notification drawer receives heads-up banner:
    * Title: `K.A.R.E.N. Request`
    * Body: `K.A.R.E.N. is waiting for your decision.`
    * Action buttons: `[APPROVE]` `[DENY]`.
  * Mac status transitions to: `[DELIVERED]`.
* **Automated Test Coverage:** `test_notification_approval_lifecycle` (PASSED).

---

### Test 3 — Approve Action
* **Objective:** Tap APPROVE on the phone and verify Mac receives the approval.
* **Steps:**
  1. On the phone, tap **APPROVE** (either from the notification drawer or inside the app).
* **Expected Result:**
  * Notification updates to: "✓ Approved by phone".
  * Mac test controller receives response and displays:
    ```
    Request ID:   <uuid>
    Outcome:      ✓ APPROVED BY PHONE
    Responded At: <timestamp>
    ```
* **Automated Test Coverage:** `test_notification_approval_lifecycle` (PASSED).

---

### Test 4 — Deny Action
* **Objective:** Send another notification, tap DENY, and verify denial on Mac.
* **Steps:**
  1. In the Mac controller, select `[3]` (Send Type B Question).
  2. On the phone, tap **NO** or **DENY**.
* **Expected Result:**
  * Notification updates to: "✗ Denied by phone".
  * Mac controller displays: `✗ DENIED BY PHONE`.
* **Automated Test Coverage:** `test_notification_denial_lifecycle` (PASSED).

---

### Test 5 — Custom Text Reply
* **Objective:** Send a question or text-reply request, type custom text, and verify exact reception on Mac.
* **Steps:**
  1. In the Mac controller, select `[4]` (Send Type C Text Response Notification).
  2. On the phone, tap **REPLY** (directly in notification drawer or inside the app).
  3. Type: `"Deploy updates at 10 PM tonight."` and tap Send.
* **Expected Result:**
  * Mac controller displays:
    ```
    Outcome:      💬 REPLIED BY PHONE
    Exact Reply:  "Deploy updates at 10 PM tonight."
    ```
* **Automated Test Coverage:** `test_custom_text_reply` (PASSED).

---

### Test 6 — Waiting & Timeout Expiration
* **Objective:** Send a notification and do not respond. Verify Mac waits without freezing and transitions to EXPIRED.
* **Steps:**
  1. In Mac controller, select `[5]` (Custom Notification).
  2. Set timeout to `10` seconds.
  3. Leave phone untouched.
* **Expected Result:**
  * Mac controller displays live elapsed timer while remaining responsive.
  * After 10 seconds, status transitions to: `⏱ EXPIRED (No response received)`.
  * Attempting to respond on the phone after expiration is rejected with an expiration error.
* **Automated Test Coverage:** `test_request_expiration` (PASSED).

---

### Test 7 — Multiple Concurrent Requests
* **Objective:** Send two different notifications simultaneously and verify responses are not mixed up.
* **Steps:**
  1. Create Request A (`APPROVE` / `DENY`).
  2. Create Request B (`REPLY`).
  3. On phone, reply to Request B first with `"Answer for B"`.
  4. Later approve Request A.
* **Expected Result:**
  * Request B completes with outcome `REPLIED` and reply text `"Answer for B"`.
  * Request A remains pending until approved, then completes with outcome `APPROVED`.
  * Responses are strictly bound to their respective `request_id`.
* **Automated Test Coverage:** `test_multiple_concurrent_requests` (PASSED).

---

### Test 8 — Network Interruption & Recovery
* **Objective:** Temporarily disconnect phone from network, re-enable, and verify synchronization.
* **Steps:**
  1. Toggle phone Airplane mode ON.
  2. Create a notification on the Mac.
  3. Toggle phone Airplane mode OFF.
* **Expected Result:**
  * App automatically reconnects WebSocket.
  * Pending requests are synchronized and appear in the pending queue.
  * Response can be submitted normally.
* **Automated Test Coverage:** OkHttp and Swift URLSession automatic reconnection handlers verified.

---

### Test 9 — Process Restart & Persistence
* **Objective:** Restart backend, Mac controller, and Android app; verify paired connection persists.
* **Steps:**
  1. Quit the Mac controller and Android app.
  2. Re-open both.
* **Expected Result:**
  * Device tokens and paired Mac details load from `PreferencesManager` (Android) and SQLite database (Mac).
  * No re-pairing is needed.

---

### Test 10 — Security & Replay Attack Prevention
* **Objective:** Attempt duplicate responses, expired responses, or unauthenticated requests.
* **Steps / Assertions:**
  1. Submit a second response to an already answered request -> rejected with **HTTP 409 Conflict**.
  2. Submit response with missing/fake bearer token -> rejected with **HTTP 401 Unauthorized**.
  3. Submit response from a revoked device -> rejected with **HTTP 401 Unauthorized**.
* **Automated Test Coverage:** `test_duplicate_response_rejection`, `test_unauthenticated_response_rejected`, `test_device_revocation` (PASSED).

