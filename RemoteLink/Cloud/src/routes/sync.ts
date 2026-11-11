/**
 * Mac Synchronization endpoint for K.A.R.E.N. Remote Link Cloud API.
 */

import { Env } from "../types";
import { getMacSyncSnapshot } from "../services/queue";
import { authenticateMac } from "../security/auth";

export async function handleMacSync(
  request: Request,
  env: Env
): Promise<Response> {
  if (!authenticateMac(request, env)) {
    return Response.json({ detail: "Unauthorized Mac sync key." }, { status: 401 });
  }

  const snapshot = await getMacSyncSnapshot(env);
  return Response.json({
    ...snapshot,
    server_time: Date.now() / 1000,
  });
}

