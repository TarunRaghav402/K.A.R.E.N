# K.A.R.E.N. Remote Link — Free-Tier & Cost Analysis

This document provides a comprehensive pricing breakdown for running K.A.R.E.N. Remote Link permanently at zero cost using free-tier services.

---

## 1. Firebase Cloud Messaging (FCM)

* **Cost:** **$0.00 / month (100% Free)**
* **Pricing Plan:** Google Firebase Spark Plan (Free).
* **Quotas & Limits:**
  * Downstream push messages: **Unlimited**.
  * Registered devices / tokens: **Unlimited**.
  * Upstream messages: **Unlimited**.
  * HTTP v1 API requests: **Unlimited** within standard Google API rate limits (~600,000 requests/minute).
* **Requirements:**
  * Free Google account.
  * No credit card is required to create a Firebase project or send FCM messages.

---

## 2. Backend Relay Hosting Options

The Backend Relay (`RemoteLink/Backend`) is a lightweight Python FastAPI / Uvicorn server requiring < 80 MB RAM.

### Option A: Local Mac Execution with Free Cloudflare Tunnel (Recommended)
* **Cost:** **$0.00 / month**
* **How it works:**
  * The backend runs directly on your Mac: `python3 RemoteLink/Backend/run_server.py`.
  * Cloudflare Tunnel provides an instant, free, secure public HTTPS/WSS URL (`https://xyz.trycloudflare.com`).
  * Works over cellular or different Wi-Fi without port forwarding or router configuration.
  * Bandwidth: **Unlimited**.
  * Time limits: **None**.

### Option B: Render Free Tier
* **Cost:** **$0.00 / month**
* **Specifications:**
  * 750 free instance hours / month (sufficient for 24/7 single-instance operation).
  * 512 MB RAM / 0.1 CPU.
  * Automatic free SSL/TLS certificate.
  * Sleeps after 15 minutes of inactivity; wakes upon incoming requests.

### Option C: Fly.io / Railway / Koyeb Free Tiers
* **Cost:** **$0.00 / month**
* **Specifications:**
  * Free allowance covers low-bandwidth microservices.
  * Persistent volume support for SQLite database.

---

## 3. Database & Storage

* **Engine:** SQLite 3 in WAL (Write-Ahead Logging) mode.
* **Cost:** **$0.00** (Zero database hosting fees).
* **Storage Footprint:**
  * Storing 10,000 pairing sessions and notification records consumes < 15 MB on disk.

---

## 4. Telephony & SMS Comparison

| Provider / API | Monthly Cost | Per-Message Cost | Used by K.A.R.E.N. Remote Link? |
| :--- | :--- | :--- | :--- |
| **Twilio SMS** | \$1.15 / phone number | \$0.0079 / SMS | **NO (Avoided)** |
| **AWS SNS SMS** | None | \$0.00645 / SMS | **NO (Avoided)** |
| **Firebase Cloud Messaging** | **$0.00** | **$0.00** | **YES (Preferred)** |
| **FastAPI WebSocket Relay** | **$0.00** | **$0.00** | **YES (Preferred)** |

---

## 5. Summary

Running K.A.R.E.N. Remote Link incurs **$0.00 monthly expense** and requires **no paid subscriptions or API tokens**.

