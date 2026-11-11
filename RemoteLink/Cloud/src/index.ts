/**
 * K.A.R.E.N. Remote Link — Cloudflare Worker API & Durable Queue.
 */

import { Env } from "./types";
import { handleHealth } from "./routes/health";
import {
  handleCreatePairingSession,
  handleGetPairingStatus,
  handlePairDevice,
} from "./routes/pairing";
import {
  handleListDevices,
  handleRevokeDevice,
  handleUpdateFCMToken,
} from "./routes/devices";
import {
  handleCreateRequest,
  handleGetPendingRequests,
  handleGetRequest,
  handleAcknowledgeDelivery,
  handleRespondToRequest,
  handleCancelRequest,
  handleClaimRequest,
  handleAcknowledgeSync,
} from "./routes/requests";
import { handleMacSync } from "./routes/sync";
import { expireOverdueRequests } from "./services/queue";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Device-ID, X-Mac-Key",
};

function addCors(response: Response): Response {
  const newHeaders = new Headers(response.headers);
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    newHeaders.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: newHeaders,
  });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/$/, ""); // trim trailing slash
    const method = request.method;

    try {
      let response: Response;

      // Health
      if ((path === "" || path === "/api/v1/health") && method === "GET") {
        response = await handleHealth(env);
      }
      // Pairing
      else if (path === "/api/v1/pairing/session" && method === "POST") {
        response = await handleCreatePairingSession(request, env);
      } else if (path.startsWith("/api/v1/pairing/status/") && method === "GET") {
        const sessionId = path.substring("/api/v1/pairing/status/".length);
        response = await handleGetPairingStatus(sessionId, env);
      } else if (path === "/api/v1/pairing/pair" && method === "POST") {
        response = await handlePairDevice(request, env);
      }
      // Devices
      else if (path === "/api/v1/devices" && method === "GET") {
        response = await handleListDevices(env);
      } else if (path.startsWith("/api/v1/devices/") && path.endsWith("/revoke") && method === "POST") {
        const deviceId = path.substring("/api/v1/devices/".length, path.length - "/revoke".length);
        response = await handleRevokeDevice(deviceId, env);
      } else if (path === "/api/v1/devices/fcm" && method === "POST") {
        response = await handleUpdateFCMToken(request, env);
      }
      // Requests
      else if (path === "/api/v1/requests" && method === "POST") {
        response = await handleCreateRequest(request, env);
      } else if (path === "/api/v1/requests/pending" && method === "GET") {
        response = await handleGetPendingRequests(env);
      } else if (path.startsWith("/api/v1/requests/") && path.endsWith("/delivered") && method === "POST") {
        const reqId = path.substring("/api/v1/requests/".length, path.length - "/delivered".length);
        response = await handleAcknowledgeDelivery(reqId, request, env);
      } else if (path.startsWith("/api/v1/requests/") && path.endsWith("/respond") && method === "POST") {
        const reqId = path.substring("/api/v1/requests/".length, path.length - "/respond".length);
        response = await handleRespondToRequest(reqId, request, env);
      } else if (path.startsWith("/api/v1/requests/") && path.endsWith("/cancel") && method === "POST") {
        const reqId = path.substring("/api/v1/requests/".length, path.length - "/cancel".length);
        response = await handleCancelRequest(reqId, env);
      } else if (path.startsWith("/api/v1/requests/") && path.endsWith("/claim") && method === "POST") {
        const reqId = path.substring("/api/v1/requests/".length, path.length - "/claim".length);
        response = await handleClaimRequest(reqId, request, env);
      } else if (path.startsWith("/api/v1/requests/") && path.endsWith("/ack") && method === "POST") {
        const reqId = path.substring("/api/v1/requests/".length, path.length - "/ack".length);
        response = await handleAcknowledgeSync(reqId, request, env);
      } else if (path.startsWith("/api/v1/requests/") && method === "GET") {
        const reqId = path.substring("/api/v1/requests/".length);
        response = await handleGetRequest(reqId, env);
      }
      // Mac Sync
      else if (path === "/api/v1/sync" && method === "GET") {
        response = await handleMacSync(request, env);
      } else {
        response = Response.json({ detail: "Endpoint not found." }, { status: 404 });
      }

      return addCors(response);
    } catch (err: any) {
      console.error(`Internal server error at ${method} ${path}:`, err);
      return addCors(
        Response.json(
          { detail: "Internal Server Error", error: err?.message || String(err) },
          { status: 500 }
        )
      );
    }
  },

  // Periodic Cron Trigger for durable queue hygiene
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(expireOverdueRequests(env));
  },
};

