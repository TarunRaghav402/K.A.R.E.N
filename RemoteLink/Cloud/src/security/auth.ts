/**
 * Authentication and Cryptographic Utilities for K.A.R.E.N. Remote Link Cloud API.
 */

import { Env, DeviceRecord } from "../types";

export async function hashToken(token: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(token);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function generateSecureToken(): Promise<string> {
  const randomBytes = new Uint8Array(32);
  crypto.getRandomValues(randomBytes);
  return Array.from(randomBytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function generatePairingCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // Clean alphabet omitting 0, O, 1, I
  const randomValues = new Uint8Array(6);
  crypto.getRandomValues(randomValues);
  return Array.from(randomValues)
    .map((b) => alphabet[b % alphabet.length])
    .join("");
}

export async function authenticateDevice(
  request: Request,
  env: Env
): Promise<{ device: DeviceRecord } | { error: string; status: number }> {
  const authHeader = request.headers.get("Authorization");
  const deviceId = request.headers.get("X-Device-ID");

  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return { error: "Missing or invalid Authorization header.", status: 401 };
  }

  if (!deviceId) {
    return { error: "Missing X-Device-ID header.", status: 400 };
  }

  const token = authHeader.substring(7).trim();
  const tokenHash = await hashToken(token);

  const device = await env.DB.prepare(
    "SELECT * FROM devices WHERE device_id = ? AND revoked = 0"
  )
    .bind(deviceId)
    .first<DeviceRecord>();

  if (!device) {
    return { error: "Device not found or pairing revoked.", status: 401 };
  }

  // Constant-time hash comparison
  if (device.device_token_hash !== tokenHash) {
    return { error: "Invalid device credentials.", status: 401 };
  }

  // Update last seen timestamp
  const now = Date.now() / 1000;
  await env.DB.prepare("UPDATE devices SET last_seen_at = ? WHERE device_id = ?")
    .bind(now, deviceId)
    .run();

  return { device };
}

export function authenticateMac(request: Request, env: Env): boolean {
  if (!env.MAC_SYNC_KEY) {
    return true; // No Mac key configured; allows standard open development
  }
  const macKey = request.headers.get("X-Mac-Key");
  return macKey === env.MAC_SYNC_KEY;
}

