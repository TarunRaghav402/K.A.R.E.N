/**
 * Notification and Request Queue endpoints for K.A.R.E.N. Remote Link Cloud API.
 */

import { Env } from "../types";
import {
  createQueueRequest,
  getQueueRequest,
  getPendingQueueRequests,
  markQueueDelivered,
  submitQueueResponse,
  cancelQueueRequest,
  claimQueueRequest,
  acknowledgeQueueSync,
} from "../services/queue";
import { authenticateDevice } from "../security/auth";

export async function handleCreateRequest(
  request: Request,
  env: Env
): Promise<Response> {
  const body = (await request.json()) as any;
  const timeoutSeconds = Number(body.timeout_seconds || env.DEFAULT_TIMEOUT_SECONDS || "120");

  const record = await createQueueRequest(env, {
    requestId: body.request_id,
    idempotencyKey: body.idempotency_key,
    type: body.type || "approval",
    title: body.title || "K.A.R.E.N. Request",
    message: body.message || "",
    details: body.details,
    actions: body.actions || ["APPROVE", "DENY"],
    timeoutSeconds: timeoutSeconds,
  });

  return Response.json(record);
}

export async function handleGetPendingRequests(env: Env): Promise<Response> {
  const pending = await getPendingQueueRequests(env);
  return Response.json(pending);
}

export async function handleGetRequest(
  requestId: string,
  env: Env
): Promise<Response> {
  const record = await getQueueRequest(env, requestId);
  if (!record) {
    return Response.json({ detail: "Request not found." }, { status: 404 });
  }
  return Response.json(record);
}

export async function handleAcknowledgeDelivery(
  requestId: string,
  request: Request,
  env: Env
): Promise<Response> {
  const auth = await authenticateDevice(request, env);
  if ("error" in auth) {
    return Response.json({ detail: auth.error }, { status: auth.status });
  }

  const success = await markQueueDelivered(env, requestId, auth.device.device_id);
  return Response.json({ success, request_id: requestId, status: "DELIVERED" });
}

export async function handleRespondToRequest(
  requestId: string,
  request: Request,
  env: Env
): Promise<Response> {
  const auth = await authenticateDevice(request, env);
  if ("error" in auth) {
    return Response.json({ detail: auth.error }, { status: auth.status });
  }

  const body = (await request.json()) as any;
  const outcome = body.outcome;
  const replyText = body.reply_text || null;

  if (!outcome) {
    return Response.json({ detail: "Missing outcome." }, { status: 400 });
  }

  const result = await submitQueueResponse(
    env,
    requestId,
    outcome,
    replyText,
    auth.device.device_id
  );

  if (!result.success) {
    if (result.duplicate) {
      return Response.json(
        { detail: result.error, record: result.record },
        { status: 409 }
      );
    }
    return Response.json({ detail: result.error }, { status: 400 });
  }

  return Response.json(result.record);
}

export async function handleCancelRequest(
  requestId: string,
  env: Env
): Promise<Response> {
  const record = await cancelQueueRequest(env, requestId);
  if (!record) {
    return Response.json(
      { detail: "Cannot cancel request (already completed or not found)." },
      { status: 400 }
    );
  }
  return Response.json(record);
}

export async function handleClaimRequest(
  requestId: string,
  request: Request,
  env: Env
): Promise<Response> {
  let consumerId = "mac-companion";
  let leaseDuration = 60;
  try {
    const body = (await request.json()) as any;
    if (body.consumer_id) consumerId = body.consumer_id;
    if (body.lease_duration) leaseDuration = Number(body.lease_duration);
  } catch {}

  const result = await claimQueueRequest(env, requestId, consumerId, leaseDuration);
  if (!result.success) {
    return Response.json({ detail: result.error }, { status: 409 });
  }
  return Response.json(result.record);
}

export async function handleAcknowledgeSync(
  requestId: string,
  request: Request,
  env: Env
): Promise<Response> {
  let markCompleted = true;
  try {
    const body = (await request.json()) as any;
    if (typeof body.completed === "boolean") {
      markCompleted = body.completed;
    }
  } catch {}

  const record = await acknowledgeQueueSync(env, requestId, markCompleted);
  if (!record) {
    return Response.json({ detail: "Request not found." }, { status: 404 });
  }
  return Response.json(record);
}

