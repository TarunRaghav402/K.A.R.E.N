"""Tests for the memory store."""
import pytest
import tempfile
from pathlib import Path
from karen_sidecar.memory import Memory


@pytest.fixture
def mem(tmp_path):
    return Memory(db_path=tmp_path / "test_memory.sqlite")


def test_propose_and_list_pending(mem):
    mid = mem.propose("User likes coffee")
    pending = mem.list_pending()
    assert any(r["id"] == mid for r in pending)
    assert mem.list_approved() == []


def test_approve(mem):
    mid = mem.propose("User's name is Alex")
    mem.approve(mid)
    approved = mem.list_approved()
    assert any(r["id"] == mid for r in approved)
    assert mem.list_pending() == []


def test_delete(mem):
    mid = mem.propose("Temporary fact")
    mem.approve(mid)
    mem.delete(mid)
    assert mem.list_approved() == []


def test_context_block_empty(mem):
    assert mem.context_block() == ""


def test_context_block_with_memory(mem):
    mid = mem.propose("Loves hiking")
    mem.approve(mid)
    block = mem.context_block()
    assert "Loves hiking" in block
    assert "[User memory]" in block


def test_chat_history_recording(mem):
    cid1 = mem.record_chat("user", "Hello Karen", "session-1")
    cid2 = mem.record_chat("assistant", "Hello! How can I assist?", "session-1")
    history = mem.get_chat_history(limit=10)
    assert len(history) == 2
    assert history[0]["role"] == "user"
    assert history[0]["content"] == "Hello Karen"
    assert history[1]["role"] == "assistant"


def test_extract_and_recall_coffee_preference(mem):
    res = mem.extract_and_save_facts("i like drinking coffee")
    assert res is not None
    assert "coffee" in res["value"]
    assert "drinking coffee" in res["content"].lower()

    # Verify saved in approved memories
    approved = mem.list_approved()
    assert any("coffee" in r["content"].lower() for r in approved)

    # Query recall
    answer = mem.find_fact_for_query("what tarun likes to drink")
    assert answer is not None
    assert "coffee" in answer.lower()
    assert "Tarun likes" in answer

    # Query recall with alternate phrasing
    answer2 = mem.find_fact_for_query("what do i like to drink")
    assert answer2 is not None
    assert "coffee" in answer2.lower()


@pytest.mark.asyncio
async def test_route_memory_learning_and_recall(mem):
    from karen_sidecar.router import route
    ctx = {"memory": mem}

    # 1. User states preference
    skill1, payload1, _ = await route("i like drinking coffee", ctx)
    assert skill1 == "memory_learn"
    assert "coffee" in payload1["reply"].lower()

    # 2. User asks what Tarun likes to drink
    skill2, payload2, _ = await route("what tarun likes to drink", ctx)
    assert skill2 == "memory_recall"
    assert "coffee" in payload2["reply"].lower()
    assert "Tarun likes" in payload2["reply"]


@pytest.mark.asyncio
async def test_route_memory_friend_learning_and_recall(mem):
    from karen_sidecar.router import route
    ctx = {"memory": mem}

    # 1. User tells Karen their friend
    skill1, payload1, _ = await route("My friend is Sriram", ctx)
    assert skill1 == "memory_learn"
    assert "Sriram" in payload1["reply"]

    # 2. User asks Karen who their friend is
    skill2, payload2, _ = await route("Who is my friend?", ctx)
    assert skill2 == "memory_recall"
    assert "Sriram" in payload2["reply"]


@pytest.mark.asyncio
async def test_confidential_statement_learning_and_recall(mem):
    from karen_sidecar.router import route
    ctx = {"memory": mem}

    # 1. Voice recognition check
    skill0, payload0, _ = await route("Do you recognize my voice?", ctx)
    assert "Tarun Raghav" in payload0["reply"]
    assert "voice" in payload0["reply"].lower()

    # 2. User saves confidential statement
    skill1, payload1, _ = await route("My confidential statement is project nebula launch code 7788", ctx)
    assert "confidential statement" in payload1["reply"].lower()
    assert "Tarun Raghav" in payload1["reply"]

    # 3. User requests confidential statement
    skill2, payload2, _ = await route("Tell me my confidential statement", ctx)
    assert "7788" in payload2["reply"]
    assert "Tarun Raghav" in payload2["reply"]


@pytest.mark.asyncio
async def test_karen_pronunciation_identity(mem):
    from karen_sidecar.router import route
    ctx = {"memory": mem}

    skill, payload, _ = await route("Who are you?", ctx)
    assert "K.A.R.E.N." in payload["reply"]
    assert "Karen" in payload["reply"]
    assert "pronounced Karen" in payload["reply"] or "pronounced as 'Karen'" in payload["reply"]


def test_pronunciation_storage_and_replacement(mem):
    mem.set_pronunciation("GIF", "Jif")
    mem.set_pronunciation("Gemini", "Jimini")

    assert mem.get_pronunciation("GIF") == "Jif"
    assert mem.get_pronunciation("gif") == "Jif"
    assert mem.get_pronunciation("Gemini") == "Jimini"
    assert mem.get_pronunciation("unknown") is None

    # Test applying pronunciations to text
    replaced = mem.apply_pronunciations("I like reading GIF files using Gemini models.")
    assert "Jif" in replaced
    assert "Jimini" in replaced
    assert "GIF" not in replaced
    assert "Gemini" not in replaced


@pytest.mark.asyncio
async def test_pronunciation_route_learning_and_query(mem):
    from karen_sidecar.router import route
    ctx = {"memory": mem}

    # 1. User teaches pronunciation
    skill1, payload1, _ = await route("The word GIF is pronounced Jif", ctx)
    assert skill1 == "pronunciation"
    assert "Jif" in payload1["reply"]
    assert mem.get_pronunciation("GIF") == "Jif"

    # 2. User asks how to pronounce
    skill2, payload2, _ = await route("How do you pronounce GIF?", ctx)
    assert skill2 == "pronunciation"
    assert "Jif" in payload2["speech_text"]

    # 3. Direct query: "Pronounce GIF"
    skill3, payload3, _ = await route("Pronounce GIF", ctx)
    assert skill3 == "pronunciation"
    assert "Jif" in payload3["speech_text"]


@pytest.mark.asyncio
async def test_tamil_pronunciation_route_learning_and_query(mem):
    from karen_sidecar.router import route
    ctx = {"memory": mem}

    # 1. Tamil learning
    skill1, payload1, _ = await route("Gemini வார்த்தையை ஜிமினி னு உச்சரி", ctx)
    assert skill1 == "pronunciation"
    assert "ஜிமினி" in payload1["reply"]
    assert mem.get_pronunciation("Gemini") == "ஜிமினி"

    # 2. Tamil query
    skill2, payload2, _ = await route("Gemini உச்சரி", ctx)
    assert skill2 == "pronunciation"
    assert "ஜிமினி" in payload2["speech_text"]
