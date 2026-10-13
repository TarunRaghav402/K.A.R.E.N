"""Tests for the MockLLM and routing."""
import pytest
import asyncio
from karen_sidecar.llm import MockLLM
from karen_sidecar.router import route


@pytest.mark.asyncio
async def test_mock_llm_returns_string():
    llm = MockLLM()
    result = await llm.complete([{"role": "user", "content": "hello"}])
    assert isinstance(result, str)
    assert len(result) > 0


@pytest.mark.asyncio
async def test_mock_llm_cycles():
    llm = MockLLM()
    responses = [await llm.complete([]) for _ in range(6)]
    # Should cycle through canned responses
    assert all(isinstance(r, str) for r in responses)


@pytest.mark.asyncio
async def test_route_time():
    skill_name, payload, needs_confirm = await route("What time is it?", {})
    assert skill_name == "time"
    assert "reply" in payload
    assert needs_confirm is False


@pytest.mark.asyncio
async def test_route_phone_unavailable():
    skill_name, payload, _ = await route("Call mom", {})
    assert skill_name == "unavailable_phone"
    assert "unavailable" in payload["reply"].lower()


@pytest.mark.asyncio
async def test_route_fallback():
    # Unknown intent with no LLM fallback set should still return gracefully
    skill_name, payload, _ = await route("sgkjhsdfkjhsdf random", {})
    # Either "unknown" or "llm" — both valid
    assert skill_name in ("unknown", "llm")
