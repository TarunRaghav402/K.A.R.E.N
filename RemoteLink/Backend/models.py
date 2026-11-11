"""Data schemas for K.A.R.E.N. Remote Link."""

from __future__ import annotations
from typing import Literal, Optional, List, Any, Dict
from pydantic import BaseModel, Field
import time
import uuid

# Lifecycle states according to spec: CREATED -> SENT -> DELIVERED -> WAITING -> RESPONDED
RequestStatus = Literal[
    "CREATED",
    "SENT",
    "DELIVERED",
    "WAITING",
    "RESPONDED",
    "EXPIRED",
    "CANCELLED",
    "DELIVERY_FAILED",
]

RequestOutcome = Literal[
    "APPROVED",
    "DENIED",
    "REPLIED",
    "EXPIRED",
    "CANCELLED",
    "DELIVERY_FAILED",
]

NotificationType = Literal["approval", "question", "text_response", "custom"]


class PairingSessionCreate(BaseModel):
    mac_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    mac_name: str = "My Mac"


class PairingSessionResponse(BaseModel):
    session_id: str
    pairing_code: str
    qr_payload: str
    mac_id: str
    mac_name: str
    expires_at: float
    is_paired: bool = False
    paired_device_id: Optional[str] = None


class PairingPairRequest(BaseModel):
    pairing_code: str
    device_id: str
    device_name: str = "Samsung Phone"
    fcm_token: Optional[str] = None


class PairingPairResponse(BaseModel):
    success: bool
    device_token: str
    mac_id: str
    mac_name: str
    paired_at: float
    message: str = "Device paired successfully."


class NotificationRequestCreate(BaseModel):
    request_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    type: NotificationType = "approval"
    title: str = "K.A.R.E.N. Request"
    message: str
    details: Optional[str] = None
    actions: List[str] = Field(default_factory=lambda: ["APPROVE", "DENY"])
    timeout_seconds: int = 120


class NotificationResponseSubmit(BaseModel):
    outcome: RequestOutcome
    reply_text: Optional[str] = None
    device_id: str


class DeliveryAckSubmit(BaseModel):
    device_id: str


class NotificationRequestRecord(BaseModel):
    request_id: str
    type: str
    title: str
    message: str
    details: Optional[str] = None
    actions: List[str]
    status: RequestStatus
    created_at: float
    sent_at: Optional[float] = None
    delivered_at: Optional[float] = None
    responded_at: Optional[float] = None
    expires_at: float
    outcome: Optional[RequestOutcome] = None
    reply_text: Optional[str] = None
    responder_device_id: Optional[str] = None


class DeviceRecord(BaseModel):
    device_id: str
    device_name: str
    device_token: str
    fcm_token: Optional[str] = None
    paired_at: float
    last_seen_at: float
    revoked: bool = False


class WebSocketEvent(BaseModel):
    event: str
    timestamp: float = Field(default_factory=time.time)
    payload: Dict[str, Any]

