# K.A.R.E.N. Remote Link — Mac Setup & Controller Guide

## 1. Prerequisites

* macOS 14.0+ (Apple Silicon or Intel).
* Python 3.13 (`sidecar/.venv/bin/python3` or system Python).
* Swift 5.9+ toolchain (Xcode or Command Line Tools).

---

## 2. Launching the Backend Relay Server

From the repository root:

```bash
cd /Users/tarunraghav/VolumeE/karen
PYTHONPATH=. sidecar/.venv/bin/python3 RemoteLink/Backend/run_server.py
```

The server binds to port `8765`:
* **Health endpoint:** `http://127.0.0.1:8765/api/v1/health`
* **Local network access:** `http://<your-mac-ip>:8765` (e.g. `http://192.168.1.4:8765`)

### Exposing over the Internet (Different Networks)
If your phone is on cellular data or a different Wi-Fi network:
Use a free Cloudflare Quick Tunnel:
```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:8765
```
This prints an instant public HTTPS URL such as `https://sample-name.trycloudflare.com`. Enter this URL in the Android app.

---

## 3. Running the Mac Test Controller

Build and run the standalone command-line controller:

```bash
cd /Users/tarunraghav/VolumeE/karen/RemoteLink/Mac
swift run karen-remote-cli
```

### Interactive Menu Options
1. **[1] Pair with Android Phone**: Generates a 6-character code and waits for phone pairing.
2. **[2] Send Type A Approval**: Sends an Approval request (`APPROVE` / `DENY`).
3. **[3] Send Type B Question**: Sends a Question request (`YES` / `NO` / `REPLY`).
4. **[4] Send Type C Text Response**: Sends a text reply request (`REPLY`).
5. **[5] Send Custom Notification**: Customize title, message, actions, and timeout.
6. **[6] Check Connection & Paired Devices**: Views relay status and active paired phones.
7. **[7] View Active / Pending Requests**: Lists requests currently waiting for response.
8. **[8] Cancel a Pending Request**: Cancels an active request.
9. **[9] Revoke Paired Device**: Disconnects and invalidates a paired phone.

### Non-Interactive CLI Automation Flags
You can automate or script test notifications:

```bash
# Pair
swift run karen-remote-cli --pair

# Send approval request
swift run karen-remote-cli --send-approval

# Send question request
swift run karen-remote-cli --send-question

# Send text response request
swift run karen-remote-cli --send-reply

# Target a remote relay server
swift run karen-remote-cli --server https://sample-name.trycloudflare.com --send-approval
```

