# K.A.R.E.N. Remote — Android App Installation & Samsung Device Guide

## 1. Locating the Pre-built APK

The application APK has been built and is located at:
```
RemoteLink/Android/app/build/outputs/apk/debug/app-debug.apk
```

---

## 2. Installation Methods

### Method A: Direct ADB Installation (Recommended if phone is connected via USB or Wi-Fi)

1. Enable **Developer Options** and **USB Debugging** on your Samsung phone:
   * Go to **Settings > About phone > Software information**.
   * Tap **Build number** 7 times.
   * Go back to **Settings > Developer options**, and toggle **USB debugging** ON.
2. Connect your phone via USB or pair via Wireless Debugging (`adb pair <ip>:<port>`).
3. Run from your Mac terminal:
   ```bash
   adb install -r /Users/tarunraghav/VolumeE/karen/RemoteLink/Android/app/build/outputs/apk/debug/app-debug.apk
   ```

### Method B: Direct File Transfer
1. Transfer `app-debug.apk` to your phone via:
   * USB Cable (Android File Transfer or Finder)
   * Google Drive / OneDrive
   * Quick Share / Local network share
2. On your Samsung phone, open the **My Files** app, navigate to **Downloads**, and tap `app-debug.apk`.
3. If prompted, allow "Install unknown apps" for My Files.
4. Tap **Install**.

---

## 3. Samsung One UI Permissions & Optimization

To ensure notifications arrive immediately and action buttons respond even when the phone has been idle:

1. **Notification Permission**:
   * On launch, tap **Allow** when the app asks to send notifications.
   * If missed, open **Settings > Apps > K.A.R.E.N. Remote > Notifications**, and enable **Allow notifications**.
2. **Battery Optimization**:
   * Samsung's aggressive battery management may sleep background apps.
   * Go to **Settings > Apps > K.A.R.E.N. Remote > Battery**.
   * Change from *Optimized* to **Unrestricted**.
3. **Lock Screen Notifications**:
   * Go to **Settings > Notifications > Lock screen notifications**.
   * Ensure notifications are set to **Show content**.

---

## 4. Pairing Your Phone with K.A.R.E.N.

1. Open **K.A.R.E.N. Remote** on your Samsung phone.
2. In the **Relay Server URL** field:
   * If on the same Wi-Fi as your Mac: Enter `http://192.168.1.4:8765`.
   * If on cellular or a different network: Enter your public HTTPS URL (e.g. `https://xxx.trycloudflare.com`).
3. On your Mac, start the CLI controller:
   ```bash
   swift run karen-remote-cli --pair
   ```
4. Enter the displayed 6-character pairing code into your phone and tap **Connect & Pair Device**.
5. Once paired, your phone displays:
   * Glowing cyan connection orb.
   * Paired Mac name.
   * Active pending requests and notification history.

