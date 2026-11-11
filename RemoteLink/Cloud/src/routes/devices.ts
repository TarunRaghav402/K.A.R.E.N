/**
 * Device management endpoints for K.A.R.E.N. Remote Link Cloud API.
 */

import { Env } from "../types";
import { authenticateDevice } from "../security/auth";

export async function handleListDevices(env: Env): Promise<Response> {
  const devices = await env.DB.prepare(
    "SELECT device_id, device_name, paired_at, last_seen_at, revoked FROM devices WHERE revoked = 0"
  ).all<any>();

  return Response.json(devices.results || []);
}

export async function handleRevokeDevice(
  deviceId: string,
  env: Env
): Promise<Response> {
  const result = await env.DB.prepare(
    "UPDATE devices SET revoked = 1 WHERE device_id = ?"
  )
    .bind(deviceId)
    .run();

  if (result.meta.changes === 0) {
    return Response.json({ detail: "Device not found." }, { status: 404 });
  }

  return Response.json({ success: true, device_id: deviceId, revoked: true });
}

export async function handleUpdateFCMToken(
  request: Request,
  env: Env
): Promise<Response> {
  const auth = await authenticateDevice(request, env);
  if ("error" in auth) {
    return Response.json({ detail: auth.error }, { status: auth.status });
  }

  const body = (await request.json()) as any;
  const fcmToken = body.fcm_token;

  if (!fcmToken) {
    return Response.json({ detail: "Missing fcm_token." }, { status: 400 });
  }

  await env.DB.prepare("UPDATE devices SET fcm_token = ? WHERE device_id = ?")
    .bind(fcmToken, auth.device.device_id)
    .run();

  return Response.json({ success: true, device_id: auth.device.device_id });
}

