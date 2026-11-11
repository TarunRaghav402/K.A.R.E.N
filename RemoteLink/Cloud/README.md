# K.A.R.E.N. Remote Link — Cloudflare Worker API & Durable D1 Queue

This directory contains the production cloud backend for K.A.R.E.N. Remote Link, running on Cloudflare Workers with Cloudflare D1 as the persistent, durable request-response store.

---

## 1. Features
- **Durable Request Queue:** Stores requests and phone responses reliably in Cloudflare D1 across Mac sleep, app closures, and network drops.
- **Firebase Cloud Messaging (FCM HTTP v1):** Direct Web Crypto RSA-SHA256 JWT assertion generation to dispatch high-priority notifications to Android.
- **Atomic State Transitions:** Strict lifecycle `STORED -> NOTIFIED -> DELIVERED -> RESPONDED -> SYNCED -> COMPLETED`.
- **Anti-Replay Protection:** Unique request UUIDs and idempotency keys with `HTTP 409 Conflict` on duplicate responses.
- **Processing Leases:** Atomic request claiming preventing double execution.

---

## 2. Local Development & Testing

Run unit & integration tests:
```bash
npx --yes tsx --test tests/worker.test.ts
```

Run local development worker with D1:
```bash
npx wrangler dev
```

---

## 3. Production Deployment

1. Login to Cloudflare:
   ```bash
   npx wrangler login
   ```
2. Create D1 database:
   ```bash
   npx wrangler d1 create karen-remote-d1
   ```
3. Update `database_id` in `wrangler.toml` with the ID printed from the step above.
4. Apply migrations:
   ```bash
   npx wrangler d1 migrations apply karen-remote-d1 --remote
   ```
5. Set FCM secret (optional for background push):
   ```bash
   npx wrangler secret put FCM_PROJECT_ID
   npx wrangler secret put FCM_CLIENT_EMAIL
   npx wrangler secret put FCM_PRIVATE_KEY
   ```
6. Deploy:
   ```bash
   npx wrangler deploy
   ```

