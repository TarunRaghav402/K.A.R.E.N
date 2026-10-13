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
