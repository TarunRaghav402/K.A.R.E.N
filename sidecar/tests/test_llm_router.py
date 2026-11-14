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
    # Unknown requests are treated as knowledge questions and use configured search.
    skill_name, payload, _ = await route("sgkjhsdfkjhsdf random", {})
    assert skill_name == "web_search"
    assert "reply" in payload


@pytest.mark.asyncio
async def test_general_knowledge_question_uses_web_search(monkeypatch):
    from karen_sidecar import router

    async def fake_search(text, context):
        return {"reply": "A laptop is a portable computer.", "speech_text": "A laptop is a portable computer."}

    monkeypatch.setattr(router, "answer_search_request", fake_search)
    skill_name, payload, needs_confirm = await route("What is a laptop?", {})
    assert skill_name == "web_search"
    assert "laptop" in payload["reply"].lower()
    assert needs_confirm is False


@pytest.mark.asyncio
async def test_route_tamil_greeting():
    skill_name, payload, _ = await route("வணக்கம்", {})
    assert skill_name == "offline_reply_catalog"
    assert "வணக்கம்" in payload["reply"]
    assert "தருண்" in payload["reply"]
    assert "ஐயா" not in payload["reply"]


@pytest.mark.asyncio
async def test_route_tamil_tanglish_greeting():
    skill_name, payload, _ = await route("vanakkam karen", {})
    assert skill_name == "offline_reply_catalog"
    assert "வணக்கம்" in payload["reply"]
    assert "ஐயா" not in payload["reply"]


@pytest.mark.asyncio
async def test_route_tamil_time():
    skill_name, payload, _ = await route("இப்போ மணி என்ன", {})
    assert skill_name == "time"
    assert "இப்போ நேரம்" in payload["reply"]
    assert "ஐயா" not in payload["reply"]


@pytest.mark.asyncio
async def test_route_tamil_identity():
    skill_name, payload, _ = await route("நீங்க யாரு", {})
    assert skill_name == "offline_reply_catalog"
    assert "கேரன்" in payload["reply"]
    assert "ஐயா" not in payload["reply"]
