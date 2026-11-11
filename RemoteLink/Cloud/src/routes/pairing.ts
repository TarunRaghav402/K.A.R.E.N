/**
 * Pairing endpoints for K.A.R.E.N. Remote Link Cloud API.
 */

import { Env, PairingSession } from "../types";
import { generatePairingCode, generateSecureToken, hashToken } from "../security/auth";

export async function handleCreatePairingSession(
  request: Request,
  env: Env
): Promise<Response> {
  let body: any = {};
  try {
    body = await request.json();
  } catch {}

  const macId = body.mac_id || crypto.randomUUID();
  const macName = body.mac_name || "My Mac";
  const sessionId = crypto.randomUUID().replace(/-/g, "");
  const code = generatePairingCode();
  const now = Date.now() / 1000;
  const expirySeconds = Number(env.PAIRING_EXPIRY_SECONDS || "300");
  const expiresAt = now + expirySeconds;

  const url = new URL(request.url);
  const serverBaseUrl = `${url.protocol}//${url.host}`;

  const qrPayload = JSON.stringify({
    karen_remote: true,
    v: 2,
    server_url: serverBaseUrl,
    session_id: sessionId,
    pairing_code: code,
    mac_id: macId,
    mac_name: macName,
    expires_at: expiresAt,
  });

  await env.DB.prepare(`
    INSERT INTO pairing_sessions (
      session_id, pairing_code, qr_payload, mac_id, mac_name, created_at, expires_at, is_paired
    ) VALUES (?, ?, ?, ?, ?, ?, ?, 0)
  `)
    .bind(sessionId, code, qrPayload, macId, macName, now, expiresAt)
    .run();

  return Response.json({
    session_id: sessionId,
    pairing_code: code,
    qr_payload: qrPayload,
    mac_id: macId,
    mac_name: macName,
    expires_at: expiresAt,
    is_paired: false,
    paired_device_id: null,
  });
}

export async function handleGetPairingStatus(
  sessionId: string,
  env: Env
): Promise<Response> {
  const session = await env.DB.prepare(
    "SELECT * FROM pairing_sessions WHERE session_id = ?"
  )
    .bind(sessionId)
    .first<PairingSession>();

  if (!session) {
    return Response.json({ detail: "Pairing session not found." }, { status: 404 });
  }

  return Response.json({
    session_id: session.session_id,
    pairing_code: session.pairing_code,
    qr_payload: session.qr_payload,
    mac_id: session.mac_id,
    mac_name: session.mac_name,
    expires_at: session.expires_at,
    is_paired: Boolean(session.is_paired),
    paired_device_id: session.paired_device_id,
  });
}

export async function handlePairDevice(
  request: Request,
  env: Env
): Promise<Response> {
  const body = (await request.json()) as any;
  const rawCode = (body.pairing_code || "").trim().toUpperCase();
  const deviceId = body.device_id;
  const deviceName = body.device_name || "Android Phone";
  const fcmToken = body.fcm_token || null;

  if (!rawCode || !deviceId) {
    return Response.json(
      { detail: "Missing pairing_code or device_id." },
      { status: 400 }
    );
  }

  const now = Date.now() / 1000;
  const session = await env.DB.prepare(
    "SELECT * FROM pairing_sessions WHERE pairing_code = ? AND expires_at > ?"
  )
    .bind(rawCode, now)
    .first<PairingSession>();

  if (!session) {
    return Response.json(
      { detail: "Invalid or expired pairing code." },
      { status: 400 }
    );
  }

  const deviceToken = await generateSecureToken();
  const tokenHash = await hashToken(deviceToken);

  // Register device in D1
  await env.DB.prepare(`
    INSERT INTO devices (
      device_id, device_name, device_token_hash, fcm_token, paired_at, last_seen_at, revoked
    ) VALUES (?, ?, ?, ?, ?, ?, 0)
    ON CONFLICT(device_id) DO UPDATE SET
      device_name = excluded.device_name,
      device_token_hash = excluded.device_token_hash,
      fcm_token = COALESCE(excluded.fcm_token, devices.fcm_token),
      last_seen_at = excluded.last_seen_at,
      revoked = 0
  `)
    .bind(deviceId, deviceName, tokenHash, fcmToken, now, now)
    .run();

  // Complete session
  await env.DB.prepare(`
    UPDATE pairing_sessions
    SET is_paired = 1, paired_device_id = ?
    WHERE session_id = ?
  `)
    .bind(deviceId, session.session_id)
    .run();

  return Response.json({
    success: true,
    device_token: deviceToken,
    mac_id: session.mac_id,
    mac_name: session.mac_name,
    paired_at: now,
    message: `Successfully paired with ${session.mac_name}.`,
  });
}

