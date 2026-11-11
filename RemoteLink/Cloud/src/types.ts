/**
 * Type definitions for K.A.R.E.N. Remote Link Cloud API.
 */

export type RequestStatus =
  | "CREATED"
  | "STORED"
  | "NOTIFIED"
  | "SENT"
  | "DELIVERED"
  | "WAITING"
  | "RESPONDED"
  | "SYNCED"
  | "COMPLETED"
  | "EXPIRED"
  | "CANCELLED"
  | "FAILED";

export type RequestOutcome =
  | "APPROVED"
  | "DENIED"
  | "REPLIED"
  | "EXPIRED"
  | "CANCELLED"
  | "DELIVERY_FAILED";

export interface Env {
  DB: D1Database;
  ENVIRONMENT?: string;
  DEFAULT_TIMEOUT_SECONDS?: string;
  PAIRING_EXPIRY_SECONDS?: string;
  LEASE_DURATION_SECONDS?: string;
  FCM_PROJECT_ID?: string;
  FCM_CLIENT_EMAIL?: string;
  FCM_PRIVATE_KEY?: string;
  MAC_SYNC_KEY?: string;
}

export interface DeviceRecord {
  device_id: string;
  device_name: string;
  device_token_hash: string;
  fcm_token: string | null;
  paired_at: number;
  last_seen_at: number;
  revoked: number;
}

export interface PairingSession {
  session_id: string;
  pairing_code: string;
  qr_payload: string;
  mac_id: string;
  mac_name: string;
  created_at: number;
  expires_at: number;
  is_paired: number;
  paired_device_id: string | null;
}

export interface NotificationRequestRecord {
  request_id: string;
  idempotency_key: string | null;
  device_id: string | null;
  type: string;
  title: string;
  message: string;
  details: string | null;
  actions: string[];
  status: RequestStatus;
  created_at: number;
  stored_at: number;
  notified_at: number | null;
  sent_at: number | null;
  delivered_at: number | null;
  responded_at: number | null;
  synced_at: number | null;
  completed_at: number | null;
  expires_at: number;
  attempt_count: number;
  outcome: RequestOutcome | null;
  reply_text: string | null;
  responder_device_id: string | null;
  lease_owner: string | null;
  lease_expires_at: number | null;
}

