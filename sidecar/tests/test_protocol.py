"""Tests for the typed protocol."""
import pytest
from karen_sidecar.protocol import (
    parse_shell_msg, TranscriptMsg, PingMsg, CancelMsg,
    StateMsg, OrbState, ReplyMsg
)


def test_parse_transcript():
    raw = {"type": "transcript", "id": "abc", "text": "hello", "final": True}
    msg = parse_shell_msg(raw)
    assert isinstance(msg, TranscriptMsg)
    assert msg.id == "abc"
    assert msg.text == "hello"
    assert msg.final is True


def test_parse_ping():
    msg = parse_shell_msg({"type": "ping"})
    assert isinstance(msg, PingMsg)


def test_parse_cancel():
    msg = parse_shell_msg({"type": "cancel", "id": "xyz"})
    assert isinstance(msg, CancelMsg)
    assert msg.id == "xyz"


def test_parse_unknown():
    with pytest.raises(ValueError):
        parse_shell_msg({"type": "mystery"})


def test_state_msg_serialisation():
    msg = StateMsg(state=OrbState.LISTENING)
    d = msg.model_dump()
    assert d["type"] == "state"
    assert d["state"] == "listening"


def test_reply_msg_serialisation():
    msg = ReplyMsg(id="1", text="Hi there", speak=True)
    j = msg.model_dump_json()
    assert '"reply"' in j
    assert "Hi there" in j
