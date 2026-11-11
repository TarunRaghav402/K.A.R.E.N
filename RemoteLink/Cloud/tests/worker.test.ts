import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index";
import { MockD1Database } from "./mock-d1";
import { Env } from "../src/types";

function createTestEnv(): Env {
  return {
    DB: new MockD1Database() as any,
    ENVIRONMENT: "test",
    DEFAULT_TIMEOUT_SECONDS: "60",
    PAIRING_EXPIRY_SECONDS: "300",
    LEASE_DURATION_SECONDS: "60",
  };
}

const mockCtx: ExecutionContext = {
  waitUntil: () => {},
  passThroughOnException: () => {},
};

test("1. Health Endpoint returns healthy and metrics", async () => {
  const env = createTestEnv();
  const req = new Request("http://localhost/api/v1/health", { method: "GET" });
  const res = await worker.fetch(req, env, mockCtx);

  assert.equal(res.status, 200);
  const data = (await res.json()) as any;
  assert.equal(data.status, "healthy");
  assert.equal(data.service, "karen-remotelink-cloud");
  assert.equal(data.durable_storage, "cloudflare-d1");
});

test("2. Pairing Lifecycle & Device Authentication", async () => {
  const env = createTestEnv();

  // Create pairing session
  const createReq = new Request("http://localhost/api/v1/pairing/session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ mac_id: "mac-test-1", mac_name: "MacBook Pro" }),
  });
  const createRes = await worker.fetch(createReq, env, mockCtx);
  assert.equal(createRes.status, 200);
  const session = (await createRes.json()) as any;
  assert.equal(session.pairing_code.length, 6);
  assert.equal(session.is_paired, false);

  // Status check before pairing
  const statusReq = new Request(
    `http://localhost/api/v1/pairing/status/${session.session_id}`,
    { method: "GET" }
  );
  const statusRes = await worker.fetch(statusReq, env, mockCtx);
  assert.equal(statusRes.status, 200);
  assert.equal(((await statusRes.json()) as any).is_paired, false);

  // Invalid pairing code rejected
  const badPairReq = new Request("http://localhost/api/v1/pairing/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      pairing_code: "XXXXXX",
      device_id: "samsung-s24",
      device_name: "Samsung Galaxy S24",
    }),
  });
  const badPairRes = await worker.fetch(badPairReq, env, mockCtx);
  assert.equal(badPairRes.status, 400);

  // Valid pairing
  const pairReq = new Request("http://localhost/api/v1/pairing/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      pairing_code: session.pairing_code,
      device_id: "samsung-s24",
      device_name: "Samsung Galaxy S24",
    }),
  });
  const pairRes = await worker.fetch(pairReq, env, mockCtx);
  assert.equal(pairRes.status, 200);
  const pairData = (await pairRes.json()) as any;
  assert.equal(pairData.success, true);
  assert.ok(pairData.device_token);

  // Verify status is paired now
  const statusRes2 = await worker.fetch(statusReq, env, mockCtx);
  const statusData2 = (await statusRes2.json()) as any;
  assert.equal(statusData2.is_paired, true);
  assert.equal(statusData2.paired_device_id, "samsung-s24");
});

test("3. Notification Request & Approval Flow", async () => {
  const env = createTestEnv();

  // Pair phone
  const sessReq = new Request("http://localhost/api/v1/pairing/session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ mac_name: "Mac" }),
  });
  const session = (await (await worker.fetch(sessReq, env, mockCtx)).json()) as any;
  const pairReq = new Request("http://localhost/api/v1/pairing/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      pairing_code: session.pairing_code,
      device_id: "phone-test",
      device_name: "Samsung Phone",
    }),
  });
  const pairData = (await (await worker.fetch(pairReq, env, mockCtx)).json()) as any;
  const token = pairData.device_token;
  const authHeaders = {
    Authorization: `Bearer ${token}`,
    "X-Device-ID": "phone-test",
    "Content-Type": "application/json",
  };

  // Create request
  const createReq = new Request("http://localhost/api/v1/requests", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      title: "K.A.R.E.N. Approval",
      message: "Please approve this action.",
      actions: ["APPROVE", "DENY"],
      timeout_seconds: 60,
    }),
  });
  const createRes = await worker.fetch(createReq, env, mockCtx);
  assert.equal(createRes.status, 200);
  const reqRecord = (await createRes.json()) as any;
  const reqId = reqRecord.request_id;
  assert.equal(reqRecord.status, "SENT");

  // Acknowledge delivery
  const delivReq = new Request(`http://localhost/api/v1/requests/${reqId}/delivered`, {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({ device_id: "phone-test" }),
  });
  const delivRes = await worker.fetch(delivReq, env, mockCtx);
  assert.equal(delivRes.status, 200);

  // Phone approves
  const respReq = new Request(`http://localhost/api/v1/requests/${reqId}/respond`, {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({ outcome: "APPROVED" }),
  });
  const respRes = await worker.fetch(respReq, env, mockCtx);
  assert.equal(respRes.status, 200);
  const finalReq = (await respRes.json()) as any;
  assert.equal(finalReq.status, "RESPONDED");
  assert.equal(finalReq.outcome, "APPROVED");
  assert.equal(finalReq.responder_device_id, "phone-test");
});

test("4. Duplicate Response Prevention (Anti-Replay)", async () => {
  const env = createTestEnv();

  // Setup device
  const sess = (await (await worker.fetch(new Request("http://localhost/api/v1/pairing/session", { method: "POST" }), env, mockCtx)).json()) as any;
  const pair = (await (await worker.fetch(new Request("http://localhost/api/v1/pairing/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pairing_code: sess.pairing_code, device_id: "phone-dup" }),
  }), env, mockCtx)).json()) as any;
  const authHeaders = {
    Authorization: `Bearer ${pair.device_token}`,
    "X-Device-ID": "phone-dup",
    "Content-Type": "application/json",
  };

  const reqRecord = (await (await worker.fetch(new Request("http://localhost/api/v1/requests", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: "Dup Test", message: "Testing single-use" }),
  }), env, mockCtx)).json()) as any;
  const reqId = reqRecord.request_id;

  // First response succeeds
  const r1 = await worker.fetch(new Request(`http://localhost/api/v1/requests/${reqId}/respond`, {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({ outcome: "APPROVED" }),
  }), env, mockCtx);
  assert.equal(r1.status, 200);

  // Second response returns 409 Conflict
  const r2 = await worker.fetch(new Request(`http://localhost/api/v1/requests/${reqId}/respond`, {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({ outcome: "DENIED" }),
  }), env, mockCtx);
  assert.equal(r2.status, 409);
});

test("5. Custom Text Reply is Persisted", async () => {
  const env = createTestEnv();

  const sess = (await (await worker.fetch(new Request("http://localhost/api/v1/pairing/session", { method: "POST" }), env, mockCtx)).json()) as any;
  const pair = (await (await worker.fetch(new Request("http://localhost/api/v1/pairing/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pairing_code: sess.pairing_code, device_id: "phone-reply" }),
  }), env, mockCtx)).json()) as any;
  const authHeaders = {
    Authorization: `Bearer ${pair.device_token}`,
    "X-Device-ID": "phone-reply",
    "Content-Type": "application/json",
  };

  const reqRecord = (await (await worker.fetch(new Request("http://localhost/api/v1/requests", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type: "text_response", title: "Reply Test", message: "What is your command?", actions: ["REPLY"] }),
  }), env, mockCtx)).json()) as any;
  const reqId = reqRecord.request_id;

  const replyText = "Deploy the release to production at 9 PM.";
  const replyRes = await worker.fetch(new Request(`http://localhost/api/v1/requests/${reqId}/respond`, {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({ outcome: "REPLIED", reply_text: replyText }),
  }), env, mockCtx);

  assert.equal(replyRes.status, 200);
  const data = (await replyRes.json()) as any;
  assert.equal(data.outcome, "REPLIED");
  assert.equal(data.reply_text, replyText);
});

test("6. Mac Synchronization Snapshot and Ack", async () => {
  const env = createTestEnv();

  // Create request and respond to it
  const sess = (await (await worker.fetch(new Request("http://localhost/api/v1/pairing/session", { method: "POST" }), env, mockCtx)).json()) as any;
  const pair = (await (await worker.fetch(new Request("http://localhost/api/v1/pairing/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pairing_code: sess.pairing_code, device_id: "phone-sync" }),
  }), env, mockCtx)).json()) as any;

  const reqRecord = (await (await worker.fetch(new Request("http://localhost/api/v1/requests", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: "Sync Test", message: "Check sync" }),
  }), env, mockCtx)).json()) as any;
  const reqId = reqRecord.request_id;

  await worker.fetch(new Request(`http://localhost/api/v1/requests/${reqId}/respond`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${pair.device_token}`,
      "X-Device-ID": "phone-sync",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ outcome: "APPROVED" }),
  }), env, mockCtx);

  // Mac calls /api/v1/sync
  const syncRes = await worker.fetch(new Request("http://localhost/api/v1/sync", { method: "GET" }), env, mockCtx);
  assert.equal(syncRes.status, 200);
  const syncData = (await syncRes.json()) as any;
  assert.ok(Array.isArray(syncData.unprocessed_responses));
  assert.equal(syncData.unprocessed_responses.length, 1);
  assert.equal(syncData.unprocessed_responses[0].request_id, reqId);

  // Mac confirms processing via /api/v1/requests/:id/ack
  const ackRes = await worker.fetch(new Request(`http://localhost/api/v1/requests/${reqId}/ack`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ completed: true }),
  }), env, mockCtx);
  assert.equal(ackRes.status, 200);
  const ackData = (await ackRes.json()) as any;
  assert.equal(ackData.status, "COMPLETED");
});

test("7. Idempotency Key Prevents Duplicate Request Creation", async () => {
  const env = createTestEnv();

  const req1 = await worker.fetch(new Request("http://localhost/api/v1/requests", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      idempotency_key: "idem-abc-123",
      title: "Idempotent Task",
      message: "Do this once",
    }),
  }), env, mockCtx);
  assert.equal(req1.status, 200);
  const data1 = (await req1.json()) as any;

  // Submit same idempotency key again
  const req2 = await worker.fetch(new Request("http://localhost/api/v1/requests", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      idempotency_key: "idem-abc-123",
      title: "Different Title",
      message: "Different Message",
    }),
  }), env, mockCtx);
  assert.equal(req2.status, 200);
  const data2 = (await req2.json()) as any;

  // Must return the exact same request ID and original record
  assert.equal(data2.request_id, data1.request_id);
  assert.equal(data2.title, data1.title);
});

test("8. Atomic Claiming with Processing Lease", async () => {
  const env = createTestEnv();

  const createRes = await worker.fetch(new Request("http://localhost/api/v1/requests", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: "Lease Task", message: "Lease testing" }),
  }), env, mockCtx);
  const reqId = ((await createRes.json()) as any).request_id;

  // Claim request
  const claim1 = await worker.fetch(new Request(`http://localhost/api/v1/requests/${reqId}/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ consumer_id: "worker-node-1", lease_duration: 60 }),
  }), env, mockCtx);
  assert.equal(claim1.status, 200);
  const claimData = (await claim1.json()) as any;
  assert.equal(claimData.lease_owner, "worker-node-1");
  assert.equal(claimData.attempt_count, 1);
});

test("9. Request Cancellation by Mac", async () => {
  const env = createTestEnv();

  const createRes = await worker.fetch(new Request("http://localhost/api/v1/requests", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title: "Cancel Test", message: "Will cancel" }),
  }), env, mockCtx);
  const reqId = ((await createRes.json()) as any).request_id;

  // Cancel
  const cancelRes = await worker.fetch(new Request(`http://localhost/api/v1/requests/${reqId}/cancel`, {
    method: "POST",
  }), env, mockCtx);
  assert.equal(cancelRes.status, 200);
  const cancelData = (await cancelRes.json()) as any;
  assert.equal(cancelData.status, "CANCELLED");
  assert.equal(cancelData.outcome, "CANCELLED");
});

