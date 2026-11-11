-- D1 Migration 0001: Initial Schema for K.A.R.E.N. Remote Link Durable Queue & Pairing

CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    device_name TEXT NOT NULL,
    device_token_hash TEXT NOT NULL,
    fcm_token TEXT,
    paired_at REAL NOT NULL,
    last_seen_at REAL NOT NULL,
    revoked INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS pairing_sessions (
    session_id TEXT PRIMARY KEY,
    pairing_code TEXT NOT NULL UNIQUE,
    qr_payload TEXT NOT NULL,
    mac_id TEXT NOT NULL,
    mac_name TEXT NOT NULL,
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    is_paired INTEGER NOT NULL DEFAULT 0,
    paired_device_id TEXT
);

CREATE TABLE IF NOT EXISTS notification_requests (
    request_id TEXT PRIMARY KEY,
    idempotency_key TEXT UNIQUE,
    device_id TEXT,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    details TEXT,
    actions_json TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at REAL NOT NULL,
    stored_at REAL NOT NULL,
    notified_at REAL,
    sent_at REAL,
    delivered_at REAL,
    responded_at REAL,
    synced_at REAL,
    completed_at REAL,
    expires_at REAL NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    outcome TEXT,
    reply_text TEXT,
    responder_device_id TEXT,
    lease_owner TEXT,
    lease_expires_at REAL
);

CREATE INDEX IF NOT EXISTS idx_requests_status ON notification_requests(status);
CREATE INDEX IF NOT EXISTS idx_requests_expires ON notification_requests(expires_at);
CREATE INDEX IF NOT EXISTS idx_pairing_code ON pairing_sessions(pairing_code);
CREATE INDEX IF NOT EXISTS idx_devices_revoked ON devices(revoked);

