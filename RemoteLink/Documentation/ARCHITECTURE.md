# K.A.R.E.N. Remote Link — Architecture & Technical Specification

## 1. System Overview

K.A.R.E.N. Remote Link is a completely independent, modular two-way communication subsystem connecting K.A.R.E.N. on macOS with an Android phone (specifically tested for Samsung Android devices).

It establishes reliable, secure, bidirectional messaging across different networks (cellular, different Wi-Fi, or over the internet) without requiring local network proximity.

```
┌─────────────────────────────────┐                    ┌─────────────────────────────────┐
│        macOS (Mac Mini /        │                    │          Android Phone          │
│       MacBook / K.A.R.E.N.)     │                    │         (Samsung Device)        │
│                                 │                    │                                 │
│  ┌───────────────────────────┐  │                    │  ┌───────────────────────────┐  │
│  │   karen-remote-cli        │  │                    │  │   K.A.R.E.N. Remote App   │  │
│  │   (Mac Test Controller)   │  │                    │  │   (Jetpack Compose UI)    │  │
│  └─────────────┬─────────────┘  │                    │  └─────────────▲─────────────┘  │
│                │                │                    │                │                │
│  ┌─────────────▼─────────────┐  │                    │  ┌─────────────┴─────────────┐  │
│  │     RemoteLinkClient      │  │                    │  │ NotificationActionReceiver│  │
│  │    (Swift 5.9 Engine)     │  │                    │  │   (Direct Reply Handler)  │  │
│  └─────────────┬─────────────┘  │                    │  └─────────────▲─────────────┘  │
└────────────────┼────────────────┘                    └────────────────┼────────────────┘
                 │                                                      │
                 │ HTTPS REST / WSS                                     │ HTTPS REST / WSS
                 ▼                                                      ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        K.A.R.E.N. Remote Link Backend Relay                            │
│                         (FastAPI / Python 3.13 / Uvicorn)                              │
│                                                                                        │
│  ┌───────────────────────────┐  ┌───────────────────────────┐  ┌────────────────────┐  │
│  │     Pairing Manager       │  │     Request Lifecycle     │  │   WebSocket Hub    │  │
│  │  (6-Char High-Entropy Code│  │     (Atomic State Engine  │  │  (Real-Time Duplex │  │
│  │   & QR Code Generator)    │  │    & Expiration Monitor)  │  │   Event Broadcast) │  │
│  └─────────────┬─────────────┘  └─────────────┬─────────────┘  └─────────▲──────────┘  │
│                │                              │                          │             │
│                ▼                              ▼                          │             │
│  ┌──────────────────────────────────────────────────────────┐            │             │
│  │                 SQLite WAL Database                      │            │             │
│  │        (devices, pairing_sessions, notification_requests)│            │             │
│  └──────────────────────────────────────────────────────────┘            │             │
│                                                                          │             │
│  ┌──────────────────────────────────────────────────────────┐            │             │
│  │                FCM HTTP v1 Dispatcher                    │────────────┘             │
│  │            (High-Priority Data Messages)                 │                          │
│  └──────────────────────────┬───────────────────────────────┘                          │
└─────────────────────────────┼──────────────────────────────────────────────────────────┘
                              │
                              │ FCM High-Priority Push
                              ▼
               ┌──────────────────────────────┐
               │  Firebase Cloud Messaging    │
               │         (Google FCM)         │
               └──────────────┬───────────────┘
                              │
                              ▼
               ┌──────────────────────────────┐
               │ KarenFirebaseMessagingService│
               │   (Android Background Push)  │
               └──────────────────────────────┘
```

---

## 2. Request Lifecycle State Machine

Every notification follows a strict, non-repudiable state machine:

```
  [CREATED]
      │
      ▼
   [SENT] ──────────────────────────┐
      │ (FCM Push / WebSocket)      │ (Mac Cancels)
      ▼                             ▼
 [DELIVERED]                   [CANCELLED]
      │                             ▲
      ▼                             │
  [WAITING] ────────────────────────┘
      │
      ├─────────────────────────────┬─────────────────────────────┐
      │ (User Taps APPROVE / YES)   │ (User Taps DENY / NO)       │ (User Sends Reply)
      ▼                             ▼                             ▼
 [RESPONDED]                   [RESPONDED]                   [RESPONDED]
Outcome: APPROVED             Outcome: DENIED               Outcome: REPLIED
      │                             │                             │
      └─────────────────────────────┴─────────────────────────────┘
                                    │
                         (Timeout Deadline Passes)
                                    ▼
                                [EXPIRED]
```

### Supported Final Outcomes
1. **`APPROVED`**: Phone tapped "APPROVE" or "YES".
2. **`DENIED`**: Phone tapped "DENY" or "NO".
3. **`REPLIED`**: Phone sent custom text reply via inline notification Direct Reply or in-app dialog.
4. **`EXPIRED`**: Configured timeout elapsed without response; missing response is **never** interpreted as approval.
5. **`CANCELLED`**: Mac revoked or cancelled the request before response.
6. **`DELIVERY_FAILED`**: Recipient phone unavailable and push delivery failed.

---

## 3. Security & Anti-Replay Model

1. **Cryptographic Token Issuance**:
   - Pairing generates a session-bound 6-character code (valid for 5 minutes).
   - Upon successful pairing, the server generates a 256-bit cryptographically secure random token (`secrets.token_urlsafe(32)`).
2. **Device Authentication**:
   - Requests from the phone must provide `Authorization: Bearer <device_token>` and `X-Device-ID: <device_id>`.
   - Verified in constant time via `secrets.compare_digest` to prevent timing attacks.
3. **Replay & Duplicate Protection**:
   - Each request has a globally unique UUID.
   - When responding, the database checks that the request is currently in `SENT`, `DELIVERED`, or `WAITING` state.
   - Transitions atomically to `RESPONDED` with the responder's device ID and timestamp.
   - Any duplicate or subsequent response attempts to the same request ID are immediately rejected with **`HTTP 409 Conflict`**.
4. **Device Revocation**:
   - Paired devices can be revoked at any time from the Mac. Once revoked, all subsequent tokens are rejected with `HTTP 401 Unauthorized`.

