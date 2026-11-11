/**
 * Health check route for K.A.R.E.N. Remote Link Cloud API.
 */

import { Env } from "../types";

export async function handleHealth(env: Env): Promise<Response> {
  const devices = await env.DB.prepare(
    "SELECT COUNT(*) as count FROM devices WHERE revoked = 0"
  ).first<{ count: number }>();

  const activeRequests = await env.DB.prepare(
    "SELECT COUNT(*) as count FROM notification_requests WHERE status IN ('STORED', 'NOTIFIED', 'SENT', 'DELIVERED', 'WAITING')"
  ).first<{ count: number }>();

  const fcmConfigured = Boolean(
    env.FCM_PROJECT_ID && env.FCM_CLIENT_EMAIL && env.FCM_PRIVATE_KEY
  );

  return Response.json(
    {
      status: "healthy",
      service: "karen-remotelink-cloud",
      version: "2.0.0",
      durable_storage: "cloudflare-d1",
      paired_devices_count: devices?.count || 0,
      active_pending_requests: activeRequests?.count || 0,
      fcm_configured: fcmConfigured,
      timestamp: Date.now() / 1000,
    },
    {
      headers: { "Content-Type": "application/json" },
    }
  );
}

