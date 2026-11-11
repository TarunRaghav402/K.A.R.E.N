# K.A.R.E.N. Remote — Phase 2: Cloud Migration & Durable Queue Architecture

## 1. System Overview

K.A.R.E.N. Remote Phase 2 upgrades the local-network link from Phase 1 into a cloud-native, zero-configuration companion architecture that operates across disparate networks (cellular data, home Wi-Fi, public hotspots, sleeping laptops, and closed mobile apps) without requiring USB debugging, manual IP configurations, or terminal daemons.

```
┌─────────────────────────────────┐                 ┌─────────────────────────────────┐
│           macOS LAPTOP          │                 │          ANDROID PHONE          │
│                                 │                 │                                 │
│  ┌───────────────────────────┐  │                 │  ┌───────────────────────────┐  │
│  │   KarenRemoteCompanion    │  │                 │  │       K.A.R.E.N. App      │  │
│  │   (Menu Bar / Background) │  │                 │  │    (Jetpack Compose UI)   │  │
│  └─────────────┬─────────────┘  │                 │  └─────────────▲─────────────┘  │
│                │                │                 │                │                │
│                │ HTTPS / REST   │                 │                │ HTTPS / REST   │
│                │ (Sync & Queue) │                 │                │                │
└────────────────┼────────────────┘                 └────────────────┼────────────────┘
                 │                                                   │
                 ▼                                                   ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                       CLOUDFLARE WORKERS (Global Edge API)                          │
│                                                                                     │
│   • Device Authentication (HMAC / SHA-256)                                          │
│   • Durable Request Queue Engine                                                    │
│   • Atomic Lease & Anti-Replay Guard                                                │
│   • Scheduled Expiration Cron Trigger                                              │
└───────────────────┬─────────────────────────────────────────▲───────────────────────┘
                    │                                         │
                    ▼                                         │
┌───────────────────────────────────────┐   ┌─────────────────┴───────────────────────┐
│     CLOUDFLARE D1 (Serverless SQL)    │   │      FIREBASE CLOUD MESSAGING (FCM)     │
│                                       │   │                                         │
│  • notification_requests (Durable)    │   │  • HTTP v1 API OAuth Assertion          │
│  • devices (Paired Tokens)            │   │  • Direct-to-Device Background Push     │
│  • pairing_sessions (Ephemeral)       │   │  • Action Buttons & RemoteInput Reply   │
└───────────────────────────────────────┘   └─────────────────────────────────────────┘
```

---

## 2. Durable Request Queue State Machine

Requests in Phase 2 transition through an authoritative lifecycle with atomic distributed state validation:

```
[ CREATED ] ──(D1 Insertion)──> [ STORED ] ──(FCM Push)──> [ NOTIFIED ]
                                                              │
                                                              ▼
                                                        [ WAITING ]
                                                              │
                 ┌────────────────────────────────────────────┴───────────────────────────┐
                 │                                                                        │
                 ▼ (User Taps Action / Enters Reply)                                     ▼ (Timeout Elapsed)
           [ RESPONDED ]                                                             [ EXPIRED ]
                 │
                 ▼ (Mac Pulls via /api/v1/sync)
            [ SYNCED ]
                 │
                 ▼ (Mac Sends /api/v1/requests/{id}/ack)
           [ COMPLETED ]
```

### State Definitions

| State | Description | Transition Trigger |
|---|---|---|
| `CREATED` | Notification payload received by API | Initial receipt |
| `STORED` | Persisted durably into D1 SQL table | SQL `INSERT` committed |
| `NOTIFIED` | Background push dispatched via FCM HTTP v1 | FCM response status 200 |
| `WAITING` | Delivered to device; awaiting user decision | Device acknowledgement / polling |
| `RESPONDED` | Phone user tapped Approve, Deny, or Replied | `POST /api/v1/requests/{id}/response` |
| `SYNCED` | Mac retrieved response snapshot during sync cycle | `GET /api/v1/sync` |
| `COMPLETED` | Mac logged response and sent ack to D1 | `POST /api/v1/requests/{id}/ack` |
| `EXPIRED` | Request reached expiration timestamp without user action | Cloudflare Cron / Query check |
| `CANCELLED` | Mac explicitly withdrew the notification prompt | `POST /api/v1/requests/{id}/cancel` |
| `DELIVERY_FAILED` | Push notification delivery failed permanently | Unregistered device token |

---

## 3. Resilience & Conflict Resolution

### 3.1 Anti-Replay Protection (HTTP 409 Conflict)
To prevent duplicate actions, race conditions, or accidental double-taps:
- When a response is received at `/api/v1/requests/{id}/response`, the SQL transaction asserts `WHERE status IN ('STORED', 'NOTIFIED', 'WAITING')`.
- If the request is already in `RESPONDED`, `SYNCED`, `COMPLETED`, `EXPIRED`, or `CANCELLED`, the API rejects the submission immediately with:
  ```json
  { "error": "Request already finalized with outcome 'APPROVED'" }
  ```
  HTTP Status: `409 Conflict`.

### 3.2 Idempotency Keys
Any request creation can include an `idempotency_key` (UUID). If the Mac reconnects or retries sending a request due to a network glitch, D1 enforces uniqueness. If a record with the same idempotency key exists, the existing record is returned without duplicating database entries or firing multiple FCM pushes.

### 3.3 Atomic Distributed Leases
When background worker instances or sync workers claim a request to process delivery, atomic leases are obtained via:
```sql
UPDATE notification_requests 
SET lease_owner = ?, lease_expires_at = ? 
WHERE request_id = ? AND (lease_expires_at IS NULL OR lease_expires_at < ?)
```
If an instance crashes, the lease expires automatically after 60 seconds and allows another instance to take over.

---

## 4. Mac Offline & Sleep Recovery

When the Mac sleeps or changes network interfaces:
1. **Sleep Detection**: `NSWorkspace.willSleepNotification` halts regular polling timers and records an offline state.
2. **Wake Recovery**: `NSWorkspace.didWakeNotification` activates a 1.5-second stabilization debounce (allowing Wi-Fi/DHCP negotiation), immediately triggers an out-of-band sync, and re-engages the background timer.
3. **Network Change Handling**: `NWPathMonitor` monitors connection interfaces. When switching between home Wi-Fi and mobile hotspot, it transitions to `reconnecting` and automatically syncs when path connectivity is satisfied.
4. **Queue Recovery**: If responses arrived while the Mac was asleep, the next `/api/v1/sync` call returns them in `unprocessed_responses`. The Mac logs each to `~/.karen/remote_responses.jsonl` and sends `/ack` to D1.

---

## 5. Free-Tier Capacity Analysis

| Component | Free-Tier Allowance | K.A.R.E.N. Remote Consumption (Daily) | Margin Remaining |
|---|---|---|---|
| **Cloudflare Workers** | 100,000 requests / day | ~5,760 syncs (at 15s interval) + ~100 actions | **94.1% free quota headroom** |
| **Cloudflare D1 Reads** | 5,000,000 reads / day | ~15,000 reads | **99.7% free quota headroom** |
| **Cloudflare D1 Writes** | 100,000 writes / day | ~500 writes | **99.5% free quota headroom** |
| **Firebase Cloud Messaging** | Unlimited free push | ~50 - 200 pushes | **100% free** |
| **Cloudflare Storage** | 1 GB total D1 storage | < 5 MB for thousands of requests | **99.5% free space** |

*Note: Cost remains \$0.00 / month on standard developer free tiers.*

