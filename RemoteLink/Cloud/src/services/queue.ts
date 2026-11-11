/**
 * Cloudflare D1 Durable Request Queue Service.
 */

import { Env, NotificationRequestRecord, RequestOutcome, RequestStatus } from "../types";
import { sendFCMNotification } from "./fcm";

interface CreateRequestParams {
  requestId?: string;
  idempotencyKey?: string | null;
  type: string;
  title: string;
  message: string;
  details?: string | null;
  actions: string[];
  timeoutSeconds: number;
}

export async function createQueueRequest(
  env: Env,
  params: CreateRequestParams
): Promise<NotificationRequestRecord> {
  const now = Date.now() / 1000;
  const requestId = params.requestId || crypto.randomUUID();
  const expiresAt = now + params.timeoutSeconds;
  const actionsJson = JSON.stringify(params.actions);

  // Check idempotency key if provided
  if (params.idempotencyKey) {
    const existing = await env.DB.prepare(
      "SELECT * FROM notification_requests WHERE idempotency_key = ?"
    )
      .bind(params.idempotencyKey)
      .first<any>();

    if (existing) {
      return formatRow(existing);
    }
  }

  // Insert atomically into D1 durable queue
  await env.DB.prepare(`
    INSERT INTO notification_requests (
      request_id, idempotency_key, type, title, message, details, actions_json,
      status, created_at, stored_at, sent_at, expires_at, attempt_count
    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'SENT', ?, ?, ?, ?, 0)
  `)
    .bind(
      requestId,
      params.idempotencyKey || null,
      params.type,
      params.title,
      params.message,
      params.details || null,
      actionsJson,
      now,
      now,
      now,
      expiresAt
    )
    .run();

  // Query back newly stored record
  const stored = await env.DB.prepare(
    "SELECT * FROM notification_requests WHERE request_id = ?"
  )
    .bind(requestId)
    .first<any>();

  const record = formatRow(stored);

  // Dispatch background FCM push notifications to all paired active devices
  const devices = await env.DB.prepare(
    "SELECT device_id, fcm_token FROM devices WHERE revoked = 0 AND fcm_token IS NOT NULL"
  ).all<{ device_id: string; fcm_token: string }>();

  if (devices.results && devices.results.length > 0) {
    for (const dev of devices.results) {
      if (dev.fcm_token) {
        sendFCMNotification(
          env,
          dev.fcm_token,
          record.request_id,
          record.type,
          record.title,
          record.message,
          record.actions,
          record.expires_at,
          record.details
        ).catch((err) => console.error("FCM dispatch error:", err));
      }
    }
  }

  return record;
}

export async function getQueueRequest(
  env: Env,
  requestId: string
): Promise<NotificationRequestRecord | null> {
  const row = await env.DB.prepare(
    "SELECT * FROM notification_requests WHERE request_id = ?"
  )
    .bind(requestId)
    .first<any>();

  return row ? formatRow(row) : null;
}

export async function getPendingQueueRequests(
  env: Env
): Promise<NotificationRequestRecord[]> {
  const now = Date.now() / 1000;
  const rows = await env.DB.prepare(`
    SELECT * FROM notification_requests
    WHERE status IN ('STORED', 'NOTIFIED', 'SENT', 'DELIVERED', 'WAITING')
      AND expires_at > ?
    ORDER BY created_at ASC
  `)
    .bind(now)
    .all<any>();

  return (rows.results || []).map(formatRow);
}

export async function claimQueueRequest(
  env: Env,
  requestId: string,
  consumerId: string,
  leaseDurationSeconds = 60
): Promise<{ success: boolean; record?: NotificationRequestRecord; error?: string }> {
  const now = Date.now() / 1000;
  const leaseExpiresAt = now + leaseDurationSeconds;

  const result = await env.DB.prepare(`
    UPDATE notification_requests
    SET lease_owner = ?, lease_expires_at = ?, attempt_count = attempt_count + 1
    WHERE request_id = ?
      AND status IN ('STORED', 'NOTIFIED', 'SENT', 'DELIVERED', 'WAITING')
      AND (lease_expires_at IS NULL OR lease_expires_at < ?)
  `)
    .bind(consumerId, leaseExpiresAt, requestId, now)
    .run();

  if (result.meta.changes === 0) {
    return { success: false, error: "Request is currently leased by another consumer or not in a claimable state." };
  }

  const updated = await getQueueRequest(env, requestId);
  return { success: true, record: updated || undefined };
}

export async function markQueueDelivered(
  env: Env,
  requestId: string,
  deviceId: string
): Promise<boolean> {
  const now = Date.now() / 1000;
  const result = await env.DB.prepare(`
    UPDATE notification_requests
    SET status = 'DELIVERED', delivered_at = ?
    WHERE request_id = ? AND status IN ('STORED', 'NOTIFIED', 'SENT')
  `)
    .bind(now, requestId)
    .run();

  return result.meta.changes > 0;
}

export async function submitQueueResponse(
  env: Env,
  requestId: string,
  outcome: RequestOutcome,
  replyText: string | null,
  deviceId: string
): Promise<{
  success: boolean;
  record?: NotificationRequestRecord;
  duplicate?: boolean;
  expired?: boolean;
  error?: string;
}> {
  const now = Date.now() / 1000;
  const current = await getQueueRequest(env, requestId);

  if (!current) {
    return { success: false, error: "Request not found." };
  }

  if (current.status === "RESPONDED" || current.status === "SYNCED" || current.status === "COMPLETED") {
    return {
      success: false,
      record: current,
      duplicate: true,
      error: "Duplicate response rejected. Request has already been answered.",
    };
  }

  if (current.status === "CANCELLED") {
    return { success: false, record: current, error: "Request was cancelled." };
  }

  if (now > current.expires_at || current.status === "EXPIRED") {
    await env.DB.prepare(
      "UPDATE notification_requests SET status = 'EXPIRED', outcome = 'EXPIRED' WHERE request_id = ?"
    )
      .bind(requestId)
      .run();
    return { success: false, expired: true, error: "Request has expired." };
  }

  const result = await env.DB.prepare(`
    UPDATE notification_requests
    SET status = 'RESPONDED', outcome = ?, reply_text = ?, responder_device_id = ?, responded_at = ?
    WHERE request_id = ? AND status IN ('STORED', 'NOTIFIED', 'SENT', 'DELIVERED', 'WAITING')
  `)
    .bind(outcome, replyText || null, deviceId, now, requestId)
    .run();

  if (result.meta.changes === 0) {
    return { success: false, error: "Concurrent conflict updating request." };
  }

  const updated = await getQueueRequest(env, requestId);
  return { success: true, record: updated || undefined };
}

export async function acknowledgeQueueSync(
  env: Env,
  requestId: string,
  markCompleted = true
): Promise<NotificationRequestRecord | null> {
  const now = Date.now() / 1000;
  const newStatus = markCompleted ? "COMPLETED" : "SYNCED";

  await env.DB.prepare(`
    UPDATE notification_requests
    SET status = ?, synced_at = ?, completed_at = ?
    WHERE request_id = ?
  `)
    .bind(newStatus, now, markCompleted ? now : null, requestId)
    .run();

  return await getQueueRequest(env, requestId);
}

export async function cancelQueueRequest(
  env: Env,
  requestId: string
): Promise<NotificationRequestRecord | null> {
  const now = Date.now() / 1000;
  await env.DB.prepare(`
    UPDATE notification_requests
    SET status = 'CANCELLED', outcome = 'CANCELLED', responded_at = ?
    WHERE request_id = ? AND status IN ('STORED', 'NOTIFIED', 'SENT', 'DELIVERED', 'WAITING')
  `)
    .bind(now, requestId)
    .run();

  return await getQueueRequest(env, requestId);
}

export async function expireOverdueRequests(
  env: Env
): Promise<NotificationRequestRecord[]> {
  const now = Date.now() / 1000;
  const overdue = await env.DB.prepare(`
    SELECT * FROM notification_requests
    WHERE status IN ('STORED', 'NOTIFIED', 'SENT', 'DELIVERED', 'WAITING')
      AND expires_at <= ?
  `)
    .bind(now)
    .all<any>();

  if (!overdue.results || overdue.results.length === 0) {
    return [];
  }

  await env.DB.prepare(`
    UPDATE notification_requests
    SET status = 'EXPIRED', outcome = 'EXPIRED', responded_at = ?
    WHERE status IN ('STORED', 'NOTIFIED', 'SENT', 'DELIVERED', 'WAITING')
      AND expires_at <= ?
  `)
    .bind(now, now)
    .run();

  return overdue.results.map(formatRow);
}

export async function getMacSyncSnapshot(
  env: Env
): Promise<{
  pending_requests: NotificationRequestRecord[];
  unprocessed_responses: NotificationRequestRecord[];
  devices: { device_id: string; device_name: string; paired_at: number; last_seen_at: number; revoked: boolean }[];
  paired_devices: { device_id: string; device_name: string; paired_at: number; last_seen_at: number; revoked: boolean }[];
}> {
  const now = Date.now() / 1000;

  // Clean up any overdue requests first
  await expireOverdueRequests(env);

  const pending = await env.DB.prepare(`
    SELECT * FROM notification_requests
    WHERE status IN ('STORED', 'NOTIFIED', 'SENT', 'DELIVERED', 'WAITING')
      AND expires_at > ?
    ORDER BY created_at ASC
  `)
    .bind(now)
    .all<any>();

  // Fetch responses that haven't been confirmed/completed by Mac
  const responses = await env.DB.prepare(`
    SELECT * FROM notification_requests
    WHERE status = 'RESPONDED'
    ORDER BY responded_at ASC
  `).all<any>();

  const devices = await env.DB.prepare(`
    SELECT device_id, device_name, paired_at, last_seen_at, revoked FROM devices WHERE revoked = 0
  `).all<any>();

  const formattedDevices = (devices.results || []).map((d) => ({
    device_id: d.device_id,
    device_name: d.device_name,
    paired_at: d.paired_at || 0,
    last_seen_at: d.last_seen_at || 0,
    revoked: Boolean(d.revoked),
  }));

  return {
    pending_requests: (pending.results || []).map(formatRow),
    unprocessed_responses: (responses.results || []).map(formatRow),
    devices: formattedDevices,
    paired_devices: formattedDevices,
  };
}

function formatRow(row: any): NotificationRequestRecord {
  let actions: string[] = ["APPROVE", "DENY"];
  try {
    if (row.actions_json) {
      actions = JSON.parse(row.actions_json);
    }
  } catch {}

  return {
    request_id: row.request_id,
    idempotency_key: row.idempotency_key || null,
    device_id: row.device_id || null,
    type: row.type,
    title: row.title,
    message: row.message,
    details: row.details || null,
    actions: actions,
    status: row.status as RequestStatus,
    created_at: Number(row.created_at),
    stored_at: Number(row.stored_at),
    notified_at: row.notified_at ? Number(row.notified_at) : null,
    sent_at: row.sent_at ? Number(row.sent_at) : null,
    delivered_at: row.delivered_at ? Number(row.delivered_at) : null,
    responded_at: row.responded_at ? Number(row.responded_at) : null,
    synced_at: row.synced_at ? Number(row.synced_at) : null,
    completed_at: row.completed_at ? Number(row.completed_at) : null,
    expires_at: Number(row.expires_at),
    attempt_count: Number(row.attempt_count || 0),
    outcome: (row.outcome as RequestOutcome) || null,
    reply_text: row.reply_text || null,
    responder_device_id: row.responder_device_id || null,
    lease_owner: row.lease_owner || null,
    lease_expires_at: row.lease_expires_at ? Number(row.lease_expires_at) : null,
  };
}

