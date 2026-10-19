"""Tests for the unified voice, text, image-label, and fact input adapter."""

import json

import pytest

from karen_sidecar.input import InputAdapter
from karen_sidecar.router import route


def test_normalize_bounds_input_and_keeps_supported_image_labels():
    normalized = InputAdapter.normalize("  What is this?  ", ["cat", "", 42, "domestic cat"])
    assert normalized == {"text": "What is this?", "image_labels": ["cat", "domestic cat"]}


def test_image_question_uses_local_classifier_labels(tmp_path):
    adapter = InputAdapter(tmp_path / "missing.json")
    assert adapter.answer_local("What is this?", ["cat (91%)"]) == "This looks like a cat (91%)."


def test_image_question_does_not_claim_person_identity(tmp_path):
    adapter = InputAdapter(tmp_path / "missing.json")
    answer = adapter.answer_local("Who is this?", ["person (88%)"])
    assert answer is not None and "cannot tell me their name" in answer


def test_image_question_uses_user_defined_object_description(tmp_path):
    source = tmp_path / "input.json"
    source.write_text(json.dumps({
        "version": 1, "facts": [],
        "objects": [{"tags": ["tabby"], "description": "This is Miso, my cat."}],
    }), encoding="utf-8")
    adapter = InputAdapter(source)
    assert adapter.answer_local("What is this?", ["tabby cat (78%)"]) == "This is Miso, my cat."


def test_user_supplied_friend_facts_are_answered(tmp_path):
    source = tmp_path / "input.json"
    source.write_text(json.dumps({
        "version": 1,
        "facts": [{"triggers": ["my friends"], "answer": "Your friends are Asha and Nikhil."}],
        "objects": [],
    }), encoding="utf-8")
    adapter = InputAdapter(source)
    assert adapter.answer_local("Who are my friends?") == "Your friends are Asha and Nikhil."


@pytest.mark.asyncio
async def test_router_answers_image_context_before_generic_fallback(tmp_path):
    adapter = InputAdapter(tmp_path / "missing.json")
    name, payload, needs_confirm = await route(
        "What is this?", {"input_adapter": adapter, "image_labels": ["dog (84%)"]}
    )
    assert name == "input"
    assert "dog" in payload["reply"]
    assert not needs_confirm
