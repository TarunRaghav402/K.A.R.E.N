# K.A.R.E.N. Remote Link — Firebase Cloud Messaging (FCM) Setup

While K.A.R.E.N. Remote Link functions out-of-the-box over high-speed real-time WebSockets and long-polling when the phone app is running, Firebase Cloud Messaging (FCM) allows notifications to wake your phone even when the app is completely terminated or locked.

---

## 1. Creating a Free Firebase Project

1. Go to the [Firebase Console](https://console.firebase.google.com/).
2. Click **Add project**, and name it (e.g. `karen-remote-link`).
3. Google Analytics can be disabled (optional).
4. Click **Create project** (100% Free under the Spark Plan).

---

## 2. Generating the Backend Service Account Key

1. In the Firebase Console, click the **Settings gear** ⚙️ next to Project Overview > **Project settings**.
2. Navigate to the **Service accounts** tab.
3. Select **Firebase Admin SDK** and click **Generate new private key**.
4. Download the generated JSON file and save it to:
   ```
   /Users/tarunraghav/.karen_remotelink/firebase-service-account.json
   ```
5. Export the environment variable before launching the backend:
   ```bash
   export KAREN_FCM_CREDENTIALS="/Users/tarunraghav/.karen_remotelink/firebase-service-account.json"
   ```

---

## 3. Configuring the Android App (Optional)

1. In Firebase Console > Project Settings, click **Add app** > **Android**.
2. Package name: `com.karen.remote`.
3. Download `google-services.json`.
4. Place it at:
   ```
   RemoteLink/Android/app/google-services.json
   ```
5. Rebuild the APK:
   ```bash
   cd RemoteLink/Android && ./gradlew assembleDebug
   ```

