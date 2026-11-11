"""Comprehensive Backend Test Suite for K.A.R.E.N. Remote Link."""

import asyncio
import os
import time
import pytest
from httpx import AsyncClient, ASGITransport

from RemoteLink.Backend.server import app, db
from RemoteLink.Backend.models import (
    PairingSessionCreate,
    PairingPairRequest,
    NotificationRequestCreate,
    NotificationResponseSubmit,
    DeliveryAckSubmit,
)


@pytest.fixture
def test_db(tmp_path):
    """Set temporary database path for test isolation."""
    test_db_path = str(tmp_path / "test_remotelink.sqlite3")
    db.db_path = test_db_path
    return test_db_path


@pytest.mark.asyncio
async def test_health_check(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/v1/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "healthy"
        assert data["service"] == "karen-remotelink-relay"
        assert "paired_devices_count" in data


@pytest.mark.asyncio
async def test_pairing_lifecycle_and_authentication(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # 1. Mac generates pairing session
        create_resp = await client.post(
            "/api/v1/pairing/session",
            json={"mac_id": "test-mac-01", "mac_name": "Tarun's MacBook"},
        )
        assert create_resp.status_code == 200
        session_data = create_resp.json()
        session_id = session_data["session_id"]
        code = session_data["pairing_code"]
        assert len(code) == 6
        assert session_data["is_paired"] is False

        # 2. Status initially shows unpaired
        status_resp = await client.get(f"/api/v1/pairing/status/{session_id}")
        assert status_resp.status_code == 200
        assert status_resp.json()["is_paired"] is False

        # 3. Invalid code rejection
        fail_pair = await client.post(
            "/api/v1/pairing/pair",
            json={"pairing_code": "WRONG1", "device_id": "phone-01", "device_name": "Samsung Galaxy S24"},
        )
        assert fail_pair.status_code == 400

        # 4. Valid code pairing
        pair_resp = await client.post(
            "/api/v1/pairing/pair",
            json={"pairing_code": code, "device_id": "phone-01", "device_name": "Samsung Galaxy S24"},
        )
        assert pair_resp.status_code == 200
        pair_data = pair_resp.json()
        assert pair_data["success"] is True
        device_token = pair_data["device_token"]
        assert len(device_token) > 20

        # 5. Status now reflects paired state
        status_resp2 = await client.get(f"/api/v1/pairing/status/{session_id}")
        assert status_resp2.status_code == 200
        assert status_resp2.json()["is_paired"] is True
        assert status_resp2.json()["paired_device_id"] == "phone-01"


@pytest.mark.asyncio
async def test_notification_approval_lifecycle(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Setup paired device
        session_resp = await client.post("/api/v1/pairing/session", json={"mac_id": "mac-01", "mac_name": "Mac"})
        code = session_resp.json()["pairing_code"]
        pair_resp = await client.post(
            "/api/v1/pairing/pair",
            json={"pairing_code": code, "device_id": "phone-test", "device_name": "Samsung Phone"},
        )
        device_token = pair_resp.json()["device_token"]
        headers = {"Authorization": f"Bearer {device_token}", "X-Device-ID": "phone-test"}

        # 1. Mac creates Type A (Approval) Notification
        req_resp = await client.post(
            "/api/v1/requests",
            json={
                "type": "approval",
                "title": "K.A.R.E.N. Request",
                "message": "K.A.R.E.N. is waiting for your decision.",
                "actions": ["APPROVE", "DENY"],
                "timeout_seconds": 60,
            },
        )
        assert req_resp.status_code == 200
        req_data = req_resp.json()
        req_id = req_data["request_id"]
        assert req_data["status"] == "SENT"

        # 2. Phone acknowledges delivery
        deliv_resp = await client.post(f"/api/v1/requests/{req_id}/delivered", headers=headers, json={"device_id": "phone-test"})
        assert deliv_resp.status_code == 200

        # Check status is DELIVERED
        check_resp = await client.get(f"/api/v1/requests/{req_id}")
        assert check_resp.json()["status"] == "DELIVERED"
        assert check_resp.json()["delivered_at"] is not None

        # 3. Phone approves request
        respond_resp = await client.post(
            f"/api/v1/requests/{req_id}/respond",
            headers=headers,
            json={"outcome": "APPROVED", "device_id": "phone-test"},
        )
        assert respond_resp.status_code == 200
        final_data = respond_resp.json()
        assert final_data["status"] == "RESPONDED"
        assert final_data["outcome"] == "APPROVED"
        assert final_data["responder_device_id"] == "phone-test"
        assert final_data["responded_at"] is not None


@pytest.mark.asyncio
async def test_notification_denial_lifecycle(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Pair device
        s = await client.post("/api/v1/pairing/session", json={"mac_id": "mac-01", "mac_name": "Mac"})
        p = await client.post(
            "/api/v1/pairing/pair",
            json={"pairing_code": s.json()["pairing_code"], "device_id": "phone-02", "device_name": "Phone"},
        )
        headers = {"Authorization": f"Bearer {p.json()['device_token']}", "X-Device-ID": "phone-02"}

        # Create request
        req = await client.post(
            "/api/v1/requests",
            json={
                "type": "question",
                "title": "K.A.R.E.N. Needs Your Response",
                "message": "Should I continue with this task?",
                "actions": ["YES", "NO", "REPLY"],
            },
        )
        req_id = req.json()["request_id"]

        # Phone denies
        resp = await client.post(
            f"/api/v1/requests/{req_id}/respond",
            headers=headers,
            json={"outcome": "DENIED", "device_id": "phone-02"},
        )
        assert resp.status_code == 200
        assert resp.json()["outcome"] == "DENIED"
        assert resp.json()["status"] == "RESPONDED"


@pytest.mark.asyncio
async def test_custom_text_reply(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Pair device
        s = await client.post("/api/v1/pairing/session", json={"mac_id": "mac-01", "mac_name": "Mac"})
        p = await client.post(
            "/api/v1/pairing/pair",
            json={"pairing_code": s.json()["pairing_code"], "device_id": "phone-03", "device_name": "Phone"},
        )
        headers = {"Authorization": f"Bearer {p.json()['device_token']}", "X-Device-ID": "phone-03"}

        # Create Type C (Text response)
        req = await client.post(
            "/api/v1/requests",
            json={
                "type": "text_response",
                "title": "Message from K.A.R.E.N.",
                "message": "Please provide the information I requested.",
                "actions": ["REPLY"],
            },
        )
        req_id = req.json()["request_id"]

        # Phone submits custom reply
        reply_msg = "Please analyze the network telemetry logs first."
        resp = await client.post(
            f"/api/v1/requests/{req_id}/respond",
            headers=headers,
            json={"outcome": "REPLIED", "reply_text": reply_msg, "device_id": "phone-03"},
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["outcome"] == "REPLIED"
        assert data["reply_text"] == reply_msg


@pytest.mark.asyncio
async def test_duplicate_response_rejection(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        s = await client.post("/api/v1/pairing/session", json={"mac_id": "mac-01", "mac_name": "Mac"})
        p = await client.post(
            "/api/v1/pairing/pair",
            json={"pairing_code": s.json()["pairing_code"], "device_id": "phone-04", "device_name": "Phone"},
        )
        headers = {"Authorization": f"Bearer {p.json()['device_token']}", "X-Device-ID": "phone-04"}

        req = await client.post(
            "/api/v1/requests",
            json={"type": "approval", "title": "Test", "message": "Test duplicate prevention"},
        )
        req_id = req.json()["request_id"]

        # First response succeeds
        r1 = await client.post(
            f"/api/v1/requests/{req_id}/respond",
            headers=headers,
            json={"outcome": "APPROVED", "device_id": "phone-04"},
        )
        assert r1.status_code == 200

        # Second response rejected with 409 Conflict (replay attack prevention)
        r2 = await client.post(
            f"/api/v1/requests/{req_id}/respond",
            headers=headers,
            json={"outcome": "DENIED", "device_id": "phone-04"},
        )
        assert r2.status_code == 409


@pytest.mark.asyncio
async def test_unauthenticated_response_rejected(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        req = await client.post(
            "/api/v1/requests",
            json={"type": "approval", "title": "Test", "message": "Test auth"},
        )
        req_id = req.json()["request_id"]

        # No auth header
        r = await client.post(
            f"/api/v1/requests/{req_id}/respond",
            json={"outcome": "APPROVED", "device_id": "attacker"},
        )
        assert r.status_code == 401

        # Invalid token
        r_bad = await client.post(
            f"/api/v1/requests/{req_id}/respond",
            headers={"Authorization": "Bearer fake_token", "X-Device-ID": "attacker"},
            json={"outcome": "APPROVED", "device_id": "attacker"},
        )
        assert r_bad.status_code == 401


@pytest.mark.asyncio
async def test_request_expiration(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        s = await client.post("/api/v1/pairing/session", json={"mac_id": "mac-01", "mac_name": "Mac"})
        p = await client.post(
            "/api/v1/pairing/pair",
            json={"pairing_code": s.json()["pairing_code"], "device_id": "phone-05", "device_name": "Phone"},
        )
        headers = {"Authorization": f"Bearer {p.json()['device_token']}", "X-Device-ID": "phone-05"}

        # Create request with 1s timeout
        req = await client.post(
            "/api/v1/requests",
            json={"type": "approval", "title": "Expiring", "message": "Quick timeout", "timeout_seconds": 1},
        )
        req_id = req.json()["request_id"]

        # Sleep past timeout
        await asyncio.sleep(1.2)

        # Trigger expiration worker check
        expired = await db.expire_pending_requests(time.time())
        assert any(r.request_id == req_id for r in expired)

        # Check request status
        check = await client.get(f"/api/v1/requests/{req_id}")
        assert check.json()["status"] == "EXPIRED"
        assert check.json()["outcome"] == "EXPIRED"

        # Attempting to respond to expired request is rejected
        r_late = await client.post(
            f"/api/v1/requests/{req_id}/respond",
            headers=headers,
            json={"outcome": "APPROVED", "device_id": "phone-05"},
        )
        assert r_late.status_code == 400


@pytest.mark.asyncio
async def test_multiple_concurrent_requests(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        s = await client.post("/api/v1/pairing/session", json={"mac_id": "mac-01", "mac_name": "Mac"})
        p = await client.post(
            "/api/v1/pairing/pair",
            json={"pairing_code": s.json()["pairing_code"], "device_id": "phone-06", "device_name": "Phone"},
        )
        headers = {"Authorization": f"Bearer {p.json()['device_token']}", "X-Device-ID": "phone-06"}

        # Create Request A (Approval) and Request B (Question)
        req_a = (await client.post("/api/v1/requests", json={"title": "Req A", "message": "Approve this"})).json()
        req_b = (await client.post("/api/v1/requests", json={"title": "Req B", "message": "Answer this"})).json()

        assert req_a["request_id"] != req_b["request_id"]

        # Respond to Req B with reply
        await client.post(
            f"/api/v1/requests/{req_b['request_id']}/respond",
            headers=headers,
            json={"outcome": "REPLIED", "reply_text": "Answer for B", "device_id": "phone-06"},
        )

        # Req A must still be pending!
        check_a = (await client.get(f"/api/v1/requests/{req_a['request_id']}")).json()
        assert check_a["status"] == "SENT"
        assert check_a["outcome"] is None

        # Req B is responded
        check_b = (await client.get(f"/api/v1/requests/{req_b['request_id']}")).json()
        assert check_b["status"] == "RESPONDED"
        assert check_b["reply_text"] == "Answer for B"

        # Now approve Req A
        await client.post(
            f"/api/v1/requests/{req_a['request_id']}/respond",
            headers=headers,
            json={"outcome": "APPROVED", "device_id": "phone-06"},
        )
        check_a_final = (await client.get(f"/api/v1/requests/{req_a['request_id']}")).json()
        assert check_a_final["status"] == "RESPONDED"
        assert check_a_final["outcome"] == "APPROVED"


@pytest.mark.asyncio
async def test_request_cancellation(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        req = (await client.post("/api/v1/requests", json={"title": "Cancel Test", "message": "Will be cancelled"})).json()
        req_id = req["request_id"]

        # Cancel
        cancel_resp = await client.post(f"/api/v1/requests/{req_id}/cancel")
        assert cancel_resp.status_code == 200
        assert cancel_resp.json()["status"] == "CANCELLED"
        assert cancel_resp.json()["outcome"] == "CANCELLED"


@pytest.mark.asyncio
async def test_device_revocation(test_db):
    await db.init_db()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        s = await client.post("/api/v1/pairing/session", json={"mac_id": "mac-01", "mac_name": "Mac"})
        p = await client.post(
            "/api/v1/pairing/pair",
            json={"pairing_code": s.json()["pairing_code"], "device_id": "phone-rev", "device_name": "Phone"},
        )
        token = p.json()["device_token"]
        headers = {"Authorization": f"Bearer {token}", "X-Device-ID": "phone-rev"}

        # Revoke device
        revoke_resp = await client.post("/api/v1/devices/phone-rev/revoke")
        assert revoke_resp.status_code == 200

        # Subsequent authenticated request fails with 401
        req = (await client.post("/api/v1/requests", json={"title": "Test", "message": "Test"})).json()
        req_id = req["request_id"]
        res = await client.post(
            f"/api/v1/requests/{req_id}/respond",
            headers=headers,
            json={"outcome": "APPROVED", "device_id": "phone-rev"},
        )
        assert res.status_code == 401
