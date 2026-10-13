"""
LLM client — pluggable provider.
Reads provider/key from env. Falls back to MockLLM when no key is set.
"""

from __future__ import annotations
import os
import asyncio
import json
import random
from abc import ABC, abstractmethod


class BaseLLM(ABC):
    @abstractmethod
    async def complete(self, messages: list[dict], *, max_tokens: int = 256) -> str:
        ...


class MockLLM(BaseLLM):
    """Useful offline conversational fallback that never makes a network call."""

    async def complete(self, messages: list[dict], *, max_tokens: int = 256) -> str:
        await asyncio.sleep(0.1)
        user_text = next((m.get("content", "") for m in reversed(messages)
                          if m.get("role") == "user"), "")
        text = user_text.strip()
        lowered = text.lower()
        if not text:
            return "I didn't catch that. Could you say it again?"
        if any(token in lowered for token in ("how are you", "are you okay", "how's it going")):
            return "I'm doing well and ready to help. What would you like to work on?"
        if any(token in lowered for token in ("your purpose", "why were you made", "what is karen")):
            return "I'm K.A.R.E.N., a voice assistant for your Mac. I can answer simple questions offline, speak replies, and help you explore the orb."
        if any(token in lowered for token in ("goodbye", "bye karen", "see you")):
            return "Goodbye! I'll be here when you need me."
        if "weather" in lowered:
            return "I can't check live weather while offline. If you connect an AI provider, I can help with more online questions."
        return random.choice([
            "I don't have a reliable answer for that yet. Could you give me a little more detail?",
            "I may have missed what you meant. Try rephrasing it, or ask for help to hear what I can do.",
            "I can help with common questions and commands offline. What would you like me to focus on?",
            "I haven't learned that one yet. If you phrase it another way, I’ll see what I can do.",
        ])


class OpenAILLM(BaseLLM):
    """OpenAI-compatible provider (also works with local servers like Ollama)."""

    def __init__(self, base_url: str, api_key: str, model: str):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model = model

    async def complete(self, messages: list[dict], *, max_tokens: int = 256) -> str:
        try:
            import httpx
        except ImportError:
            return "[httpx not installed — using offline mock]"

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }
        body = {"model": self.model, "messages": messages, "max_tokens": max_tokens}
        async with httpx.AsyncClient(timeout=30) as client:
            r = await client.post(f"{self.base_url}/chat/completions", headers=headers, json=body)
            r.raise_for_status()
            return r.json()["choices"][0]["message"]["content"].strip()


def build_llm() -> BaseLLM:
    """Factory — reads KAREN_LLM_PROVIDER, KAREN_LLM_KEY, KAREN_LLM_MODEL from env."""
    provider = os.environ.get("KAREN_LLM_PROVIDER", "mock").lower()
    if provider == "mock" or not os.environ.get("KAREN_LLM_KEY"):
        print("[llm] Using offline MockLLM (set KAREN_LLM_PROVIDER + KAREN_LLM_KEY to enable real LLM)")
        return MockLLM()

    api_key   = os.environ["KAREN_LLM_KEY"]
    model     = os.environ.get("KAREN_LLM_MODEL", "gpt-4o-mini")
    base_url  = os.environ.get("KAREN_LLM_BASE_URL", "https://api.openai.com/v1")
    print(f"[llm] Provider: {provider}, model: {model}, base: {base_url}")
    return OpenAILLM(base_url=base_url, api_key=api_key, model=model)
