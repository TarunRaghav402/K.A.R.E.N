"""FastAPI Relay Server for K.A.R.E.N. Remote Link."""

from __future__ import annotations
import asyncio
import json
import secrets
import string
import time
from contextlib import asynccontextmanager
from typing import Dict, Set, Optional, List

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Header, Depends, Query, status
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .database import Database
from .models import (
    PairingSessionCreate,
    PairingSessionResponse,
    PairingPairRequest,
    PairingPairResponse,
    NotificationRequestCreate,
    NotificationRequestRecord,
    NotificationResponseSubmit,
    DeliveryAckSubmit,
    DeviceRecord,
    WebSocketEvent,
)
from .fcm import FCMDispatcher

# ─── Hub for Active WebSockets ─────────────────────────────────────────────────

class ConnectionHub:
    def __init__(self) -> None:
        self.mac_connections: Set[WebSocket] = set()
        self.phone_connections: Dict[str, Set[WebSocket]] = {}

    async def connect_mac(self, ws: WebSocket) -> None:
        await ws.accept()
        self.mac_connections.add(ws)

    def disconnect_mac(self, ws: WebSocket) -> None:
        self.mac_connections.discard(ws)

    async def connect_phone(self, device_id: str, ws: WebSocket) -> None:
        await ws.accept()
        if device_id not in self.phone_connections:
            self.phone_connections[device_id] = set()
        self.phone_connections[device_id].add(ws)

    def disconnect_phone(self, device_id: str, ws: WebSocket) -> None:
        if device_id in self.phone_connections:
            self.phone_connections[device_id].discard(ws)
            if not self.phone_connections[device_id]:
                del self.phone_connections[device_id]

    async def broadcast_to_mac(self, event_name: str, payload: dict) -> None:
        event = WebSocketEvent(event=event_name, payload=payload)
        data = event.model_dump_json()
        to_remove = set()
        for ws in self.mac_connections:
            try:
                await ws.send_text(data)
            except Exception:
                to_remove.add(ws)
        self.mac_connections.difference_update(to_remove)

    async def broadcast_to_phones(self, event_name: str, payload: dict, target_device_id: Optional[str] = None) -> None:
        event = WebSocketEvent(event=event_name, payload=payload)
        data = event.model_dump_json()
        if target_device_id:
            sockets = self.phone_connections.get(target_device_id, set())
            for ws in list(sockets):
                try:
                    await ws.send_text(data)
                except Exception:
                    self.disconnect_phone(target_device_id, ws)
        else:
            for dev_id, sockets in list(self.phone_connections.items()):
                for ws in list(sockets):
                    try:
                        await ws.send_text(data)
                    except Exception:
                        self.disconnect_phone(dev_id, ws)


db = Database()
hub = ConnectionHub()
fcm = FCMDispatcher()


# ─── Background Expiration Task ───────────────────────────────────────────────

async def expiration_monitor() -> None:
    """Continuously monitors and expires requests whose timeout deadline has elapsed."""
    while True:
        try:
            now = time.time()
            expired_requests = await db.expire_pending_requests(now)
            for req in expired_requests:
                await hub.broadcast_to_mac(
                    "request_expired",
                    {"request_id": req.request_id, "status": "EXPIRED", "outcome": "EXPIRED", "expired_at": now},
                )
                await hub.broadcast_to_phones(
                    "request_expired",
                    {"request_id": req.request_id, "status": "EXPIRED", "outcome": "EXPIRED"},
                )
        except Exception as e:
            print(f"[RemoteLink Server] Error in expiration monitor: {e}")
        await asyncio.sleep(settings.cleanup_interval_seconds)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.init_db()
    task = asyncio.create_task(expiration_monitor())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


app = FastAPI(
    title="K.A.R.E.N. Remote Link Backend Relay",
    version="1.0.0",
    description="Secure communication relay between K.A.R.E.N. macOS shell and Android phone application.",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─── Health ───────────────────────────────────────────────────────────────────

@app.get("/api/v1/health")
async def health():
    devices = await db.get_active_devices()
    return {
        "status": "healthy",
        "service": "karen-remotelink-relay",
        "version": "1.0.0",
        "paired_devices_count": len(devices),
        "connected_mac_clients": len(hub.mac_connections),
        "connected_phone_clients": sum(len(s) for s in hub.phone_connections.values()),
        "fcm_configured": fcm._project_id is not None,
    }


# ─── Pairing ──────────────────────────────────────────────────────────────────

def generate_pairing_code() -> str:
    """Generates a high-entropy 6-character alphanumeric pairing code (e.g. 7K9P2X)."""
    alphabet = string.ascii_uppercase + string.digits
    # Avoid visually ambiguous characters 0, O, 1, I
    clean_alphabet = "".join(ch for ch in alphabet if ch not in "0O1I")
    return "".join(secrets.choice(clean_alphabet) for _ in range(6))


@app.post("/api/v1/pairing/session", response_model=PairingSessionResponse)
async def create_pairing_session(payload: PairingSessionCreate):
    session_id = secrets.token_hex(16)
    code = generate_pairing_code()
    expires_at = time.time() + settings.pairing_code_expiry_seconds

    # QR payload contains JSON with server URL, session ID, and pairing code
    qr_data = {
        "karen_remote": True,
        "v": 1,
        "server_url": settings.server_base_url,
        "session_id": session_id,
        "pairing_code": code,
        "mac_id": payload.mac_id,
        "mac_name": payload.mac_name,
        "expires_at": expires_at,
    }
    qr_payload = json.dumps(qr_data)

    return await db.create_pairing_session(
        session_id=session_id,
        code=code,
        qr_payload=qr_payload,
        mac_id=payload.mac_id,
        mac_name=payload.mac_name,
        expires_at=expires_at,
    )


@app.get("/api/v1/pairing/status/{session_id}", response_model=PairingSessionResponse)
async def get_pairing_status(session_id: str):
    session = await db.get_pairing_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Pairing session not found.")
    return session


@app.post("/api/v1/pairing/pair", response_model=PairingPairResponse)
async def pair_device(payload: PairingPairRequest):
    code = payload.pairing_code.strip().upper()
    session = await db.get_pairing_session_by_code(code)
    if not session:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid or expired pairing code. Please enter the active code shown on your Mac.",
        )

    # Generate secure device authentication token
    device_token = secrets.token_urlsafe(32)

    # Register phone device
    device = await db.register_device(
        device_id=payload.device_id,
        device_name=payload.device_name,
        device_token=device_token,
        fcm_token=payload.fcm_token,
    )

    # Complete the pairing session
    await db.complete_pairing_session(session.session_id, device.device_id)

    # Broadcast event to Mac
    await hub.broadcast_to_mac(
        "device_paired",
        {
            "device_id": device.device_id,
            "device_name": device.device_name,
            "paired_at": device.paired_at,
            "session_id": session.session_id,
        },
    )

    return PairingPairResponse(
        success=True,
        device_token=device_token,
        mac_id=session.mac_id,
        mac_name=session.mac_name,
        paired_at=device.paired_at,
        message=f"Successfully paired with {session.mac_name}.",
    )


# ─── Device Authentication Helper ─────────────────────────────────────────────

async def get_authenticated_device(
    authorization: Optional[str] = Header(None), x_device_id: Optional[str] = Header(None)
) -> DeviceRecord:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing or invalid Authorization header.")

    token = authorization[len("Bearer ") :].strip()
    if not x_device_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Missing X-Device-ID header.")

    device = await db.get_device(x_device_id)
    if not device or device.revoked:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Device not found or pairing revoked.")

    if not secrets.compare_digest(device.device_token, token):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid device credentials.")

    await db.update_device_last_seen(device.device_id)
    return device


# ─── Requests ─────────────────────────────────────────────────────────────────

@app.post("/api/v1/requests", response_model=NotificationRequestRecord)
async def create_notification_request(payload: NotificationRequestCreate):
    """Mac creates a new notification request."""
    req = await db.create_request(
        request_id=payload.request_id,
        req_type=payload.type,
        title=payload.title,
        message=payload.message,
        details=payload.details,
        actions=payload.actions,
        timeout_seconds=payload.timeout_seconds,
    )

    # Broadcast to connected phones via real-time WebSocket
    req_dict = req.model_dump()
    await hub.broadcast_to_phones("request_created", req_dict)

    # Broadcast to Mac so all listeners observe SENT state
    await hub.broadcast_to_mac("request_sent", req_dict)

    # Push to all paired devices with FCM tokens
    active_devices = await db.get_active_devices()
    for dev in active_devices:
        if dev.fcm_token:
            asyncio.create_task(
                fcm.send_notification(
                    fcm_token=dev.fcm_token,
                    request_id=req.request_id,
                    req_type=req.type,
                    title=req.title,
                    message=req.message,
                    actions=req.actions,
                    expires_at=req.expires_at,
                    details=req.details,
                )
            )

    return req


@app.get("/api/v1/requests/pending", response_model=List[NotificationRequestRecord])
async def get_pending_requests():
    """Returns active pending requests."""
    return await db.get_pending_requests()


@app.get("/api/v1/requests/{request_id}", response_model=NotificationRequestRecord)
async def get_request_status(request_id: str):
    req = await db.get_request(request_id)
    if not req:
        raise HTTPException(status_code=404, detail="Request not found.")
    return req


@app.post("/api/v1/requests/{request_id}/delivered")
async def acknowledge_delivery(
    request_id: str,
    payload: DeliveryAckSubmit,
    device: DeviceRecord = Depends(get_authenticated_device),
):
    """Phone acknowledges that notification was delivered."""
    delivered = await db.mark_request_delivered(request_id, device.device_id)
    if delivered:
        now = time.time()
        await hub.broadcast_to_mac(
            "request_delivered",
            {"request_id": request_id, "device_id": device.device_id, "delivered_at": now, "status": "DELIVERED"},
        )
    return {"success": True, "request_id": request_id, "status": "DELIVERED"}


@app.post("/api/v1/requests/{request_id}/respond", response_model=NotificationRequestRecord)
async def respond_to_request(
    request_id: str,
    payload: NotificationResponseSubmit,
    device: DeviceRecord = Depends(get_authenticated_device),
):
    """Phone submits decision (APPROVE / DENY / REPLIED). Enforces single-use & deduplication."""
    success, updated_req, err_msg = await db.mark_request_responded(
        request_id=request_id,
        outcome=payload.outcome,
        reply_text=payload.reply_text,
        device_id=device.device_id,
    )

    if not success:
        if "duplicate" in (err_msg or "").lower() or (updated_req and updated_req.status == "RESPONDED"):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=err_msg or "Duplicate response rejected. Request already completed.",
            )
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=err_msg or "Could not process response.",
        )

    assert updated_req is not None
    # Broadcast to Mac immediately
    await hub.broadcast_to_mac("request_responded", updated_req.model_dump())

    # Broadcast to other phone connections to dismiss notification
    await hub.broadcast_to_phones("request_responded", updated_req.model_dump())

    return updated_req


@app.post("/api/v1/requests/{request_id}/cancel", response_model=NotificationRequestRecord)
async def cancel_request(request_id: str):
    """Mac cancels a pending request."""
    success, updated_req = await db.mark_request_cancelled(request_id)
    if not success or not updated_req:
        raise HTTPException(status_code=400, detail="Cannot cancel request (already finalized or not found).")

    await hub.broadcast_to_mac("request_cancelled", updated_req.model_dump())
    await hub.broadcast_to_phones("request_cancelled", updated_req.model_dump())
    return updated_req


# ─── Devices Management ───────────────────────────────────────────────────────

@app.get("/api/v1/devices", response_model=List[DeviceRecord])
async def list_devices():
    return await db.get_active_devices()


@app.post("/api/v1/devices/{device_id}/revoke")
async def revoke_device(device_id: str):
    success = await db.revoke_device(device_id)
    if not success:
        raise HTTPException(status_code=404, detail="Device not found.")
    await hub.broadcast_to_mac("device_revoked", {"device_id": device_id})
    return {"success": True, "device_id": device_id, "revoked": True}


# ─── WebSockets ───────────────────────────────────────────────────────────────

@app.websocket("/api/v1/ws/mac")
async def mac_websocket(ws: WebSocket):
    await hub.connect_mac(ws)
    try:
        # Send initial handshake
        await ws.send_text(
            json.dumps({"event": "connected", "role": "mac", "timestamp": time.time()})
        )
        while True:
            data = await ws.receive_text()
            # Handle client ping or keepalive
            try:
                msg = json.loads(data)
                if msg.get("type") == "ping":
                    await ws.send_text(json.dumps({"type": "pong", "timestamp": time.time()}))
            except Exception:
                pass
    except WebSocketDisconnect:
        pass
    finally:
        hub.disconnect_mac(ws)


@app.websocket("/api/v1/ws/phone")
async def phone_websocket(
    ws: WebSocket,
    device_id: str = Query(...),
    token: str = Query(...),
):
    # Verify device authentication
    device = await db.get_device(device_id)
    if not device or device.revoked or not secrets.compare_digest(device.device_token, token):
        await ws.close(code=status.WS_1008_POLICY_VIOLATION)
        return

    await hub.connect_phone(device_id, ws)
    try:
        await ws.send_text(
            json.dumps({"event": "connected", "role": "phone", "device_id": device_id, "timestamp": time.time()})
        )
        while True:
            data = await ws.receive_text()
            try:
                msg = json.loads(data)
                if msg.get("type") == "ping":
                    await ws.send_text(json.dumps({"type": "pong", "timestamp": time.time()}))
            except Exception:
                pass
    except WebSocketDisconnect:
        pass
    finally:
        hub.disconnect_phone(device_id, ws)

