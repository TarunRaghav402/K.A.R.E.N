# K.A.R.E.N. Remote — Phase 2: Cloud Deployment & Setup Guide

This guide walks through deploying the K.A.R.E.N. Remote cloud infrastructure using **100% free-tier services**:
- **Cloudflare Workers** (API hosting — 100,000 requests/day free)
- **Cloudflare D1** (Serverless SQL Durable Request Queue — 5M reads/day, 100k writes/day free)
- **Firebase Cloud Messaging (FCM HTTP v1)** (Background push notifications — completely free)

---

## Prerequisites

1. **Node.js 18+** installed (`node -v`).
2. A free [Cloudflare Account](https://dash.cloudflare.com/).
3. A free [Firebase Account](https://console.firebase.google.com/).
4. An Android phone running Android 10+ (Samsung Galaxy recommended).
5. macOS 13+ with Xcode / Swift toolchain.

---

## Step 1: Deploy Cloud Backend (Cloudflare Workers & D1)

### 1.1 Authenticate Wrangler CLI
From your terminal, navigate to the Cloud backend directory:
```bash
cd RemoteLink/Cloud
npx wrangler login
```
A browser window will open asking you to authorize Wrangler. Click **Allow**.

### 1.2 Create the D1 Database
Create the production D1 database:
```bash
npx wrangler d1 create karen-remote-d1
```
Output will display your database binding:
```toml
[[d1_databases]]
binding = "DB"
database_name = "karen-remote-d1"
database_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

Copy the `database_id` and replace the placeholder in `RemoteLink/Cloud/wrangler.toml`:
```toml
[[d1_databases]]
binding = "DB"
database_name = "karen-remote-d1"
database_id = "PASTE_YOUR_DATABASE_ID_HERE"
```

### 1.3 Apply Schema Migrations
Apply the initial schema to both local development and remote production:
```bash
# Local test environment
npx wrangler d1 execute karen-remote-d1 --local --file=./migrations/0001_initial_schema.sql

# Production cloud environment
npx wrangler d1 execute karen-remote-d1 --remote --file=./migrations/0001_initial_schema.sql
```

---

## Step 2: Configure Firebase Cloud Messaging (FCM HTTP v1)

FCM sends silent, high-priority background push notifications to wake your Android device even when the app is closed.

### 2.1 Create Firebase Project
1. Go to the [Firebase Console](https://console.firebase.google.com/) and click **Add project**.
2. Name it `Karen Remote` (disable Google Analytics if desired).
3. Add an Android app with package name:
   ```
   com.karen.remote
   ```
4. Download `google-services.json` and place it at:
   ```
   RemoteLink/Android/app/google-services.json
   ```

### 2.2 Generate Service Account Credentials
1. In Firebase Console, go to **Project Settings** (gear icon) > **Service accounts**.
2. Click **Generate new private key** and download the JSON file.
3. Open the downloaded JSON file and extract three values:
   - `project_id`
   - `client_email`
   - `private_key` (the PEM string including `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----`)

### 2.3 Store Secrets in Cloudflare Worker
Set the credentials securely via Wrangler:
```bash
cd RemoteLink/Cloud
npx wrangler secret put FCM_PROJECT_ID
# Enter your project_id

npx wrangler secret put FCM_CLIENT_EMAIL
# Enter your client_email

npx wrangler secret put FCM_PRIVATE_KEY
# Enter your private_key (including newlines and PEM delimiters)
```

*(Optional)* If you wish to protect Mac administrative endpoints, set an optional Mac key:
```bash
npx wrangler secret put MAC_API_KEY
# Enter any secure random passphrase
```

### 2.4 Deploy the Cloudflare Worker
Deploy the worker to the global edge network:
```bash
npx wrangler deploy
```
Wrangler will output your live URL:
```
https://karen-remote.<your-subdomain>.workers.dev
```

Test the live deployment:
```bash
curl https://karen-remote.<your-subdomain>.workers.dev/api/v1/health
```
Expected output:
```json
{"status":"healthy","service":"karen-remote-cloud","paired_devices_count":0,"durable_queue":true}
```

---

## Step 3: Configure and Build Android Companion App

### 3.1 Build Android APK
Ensure `google-services.json` is located in `RemoteLink/Android/app/`.
Build the debug APK:
```bash
cd RemoteLink/Android
./gradlew assembleDebug
```
The compiled APK will be at:
`RemoteLink/Android/app/build/outputs/apk/debug/app-debug.apk`

### 3.2 Install and Connect
1. Transfer `app-debug.apk` to your Android phone (via AirDroid, LocalSend, email, or `adb install`).
2. Open the **K.A.R.E.N. Remote** app on your phone.
3. Tap the **Settings** (gear icon) in the top-right corner.
4. In **Relay Server URL**, enter your Cloudflare Worker URL:
   ```
   https://karen-remote.<your-subdomain>.workers.dev
   ```
5. Tap **Save Settings**.
6. Follow the on-screen pairing prompts (enter the 6-character code from your Mac or scan QR code).

### 3.3 Samsung Battery Optimization Advice
On Samsung One UI devices:
1. Open **Settings** > **Apps** > **K.A.R.E.N. Remote**.
2. Tap **Battery** and select **Unrestricted**.
3. Under **Device Care** > **Battery** > **Background usage limits**, ensure K.A.R.E.N. Remote is added to **Never sleeping apps**.

---

## Step 4: Configure macOS Companion & LaunchAgent

The macOS companion runs as an unobtrusive menu-bar item with automatic network recovery and sleep/wake listeners.

### 4.1 Build the Companion Binary
```bash
cd RemoteLink/MacCompanion
swift build -c release
```
The binary will be compiled to:
`RemoteLink/MacCompanion/.build/release/karen-companion`

### 4.2 Configure Local Settings
Create or edit `~/.karen/remote_link_cloud_config.json`:
```json
{
  "cloud_url": "https://karen-remote.<your-subdomain>.workers.dev",
  "mac_id": "unique-mac-id",
  "mac_name": "My MacBook",
  "poll_interval_seconds": 15
}
```

### 4.3 Install LaunchAgent for Automatic Login Start
To automatically start the companion in the menu bar when logging into your Mac:
```bash
RemoteLink/MacCompanion/.build/release/karen-companion --install-agent
```
To verify status or remove:
```bash
# Check status
RemoteLink/MacCompanion/.build/release/karen-companion --status

# Uninstall
RemoteLink/MacCompanion/.build/release/karen-companion --uninstall-agent
```

### 4.4 Launch the Companion Interactively
You can launch the menu bar app right now:
```bash
RemoteLink/MacCompanion/.build/release/karen-companion &
```
A circular indicator will appear in the top macOS menu bar:
- 🔵 **Connected** (Communicating with Cloudflare D1)
- 🟡 **Reconnecting / Syncing**
- ⚪️ **Offline**

Clicking the item reveals pending requests, last sync time, "Sync Now", "Send Test Action Prompt", and "Open Response Journal".

