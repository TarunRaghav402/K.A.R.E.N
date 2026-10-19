"""
Typed JSON protocol shared between Swift shell and Python sidecar.

Message schema (all messages are JSON objects with a "type" field):

Shell → Sidecar:
  { "type": "transcript",  "id": str, "text": str, "final": bool }
  { "type": "ping" }
  { "type": "cancel",      "id": str }

Sidecar → Shell:
  { "type": "state",       "state": OrbState }
  { "type": "reply",       "id": str, "text": str, "speak": bool, "speech_text": str | None }
  { "type": "action",      "id": str, "skill": str, "payload": dict, "needs_confirm": bool }
  { "type": "error",       "id": str, "message": str }
  { "type": "pong" }

OrbState values: "idle" | "listening" | "processing" | "speaking" | "permission" | "error"
"""

from __future__ import annotations
from enum import StrEnum
from typing import Any, Literal
from pydantic import BaseModel, Field


class OrbState(StrEnum):
    IDLE       = "idle"
    LISTENING  = "listening"
    PROCESSING = "processing"
    SPEAKING   = "speaking"
    PERMISSION = "permission"
    ERROR      = "error"


# ---------- Shell → Sidecar ----------

class TranscriptMsg(BaseModel):
    type: Literal["transcript"] = "transcript"
    id: str
    text: str
    final: bool = True
    source: Literal["voice", "text"] = "voice"
    image_labels: list[str] = Field(default_factory=list)


class PingMsg(BaseModel):
    type: Literal["ping"] = "ping"


class CancelMsg(BaseModel):
    type: Literal["cancel"] = "cancel"
    id: str


# ---------- Sidecar → Shell ----------

class StateMsg(BaseModel):
    type: Literal["state"] = "state"
    state: OrbState


class ReplyMsg(BaseModel):
    type: Literal["reply"] = "reply"
    id: str
    text: str
    speak: bool = True
    speech_text: str | None = None


class ActionMsg(BaseModel):
    type: Literal["action"] = "action"
    id: str
    skill: str
    payload: dict[str, Any] = Field(default_factory=dict)
    needs_confirm: bool = False


class ErrorMsg(BaseModel):
    type: Literal["error"] = "error"
    id: str
    message: str


class PongMsg(BaseModel):
    type: Literal["pong"] = "pong"


AnyShellMsg = TranscriptMsg | PingMsg | CancelMsg
AnySidecarMsg = StateMsg | ReplyMsg | ActionMsg | ErrorMsg | PongMsg


def parse_shell_msg(raw: dict[str, Any]) -> AnyShellMsg:
    t = raw.get("type")
    if t == "transcript":
        return TranscriptMsg(**raw)
    if t == "ping":
        return PingMsg()
    if t == "cancel":
        return CancelMsg(**raw)
    raise ValueError(f"Unknown shell message type: {t}")
