"""Orchestration helpers for search queries and Gemini Google Search grounding."""

from __future__ import annotations
from typing import Any
from .llm import MockLLM


async def answer_search_request(text: str, context: dict[str, Any]) -> dict[str, Any]:
    """Handles search requests when in offline mode or routes to Gemini grounding."""
    llm = context.get("llm")
    if llm is not None and not isinstance(llm, MockLLM):
        # Gemini handles search queries natively using Google Search grounding
        return {}

    return {
        "reply": "Live Google Search and web intelligence require a Google Gemini API key. You can add your key in K.A.R.E.N. Settings.",
        "speech_text": "Live web search requires a Gemini API key. Please add your key in Settings.",
    }
