"""
LLM client — Google Gemini API provider.
Falls back to MockLLM only when offline mode is explicitly requested or no key is configured.
"""

from __future__ import annotations
import os
import asyncio
import re
from typing import Any
from abc import ABC, abstractmethod
import httpx


DEFAULT_GEMINI_MODEL = "gemini-3.1-flash-lite"
FALLBACK_GEMINI_MODELS = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite-preview", "gemini-flash-lite-latest", "gemini-2.5-flash-lite"]


class LLMResponse(str):
    """String response that also carries speech text, citations, and search queries."""

    text: str
    speech_text: str
    sources: list[dict[str, str]]
    search_queries: list[str]

    def __new__(
        cls,
        text: str,
        speech_text: str | None = None,
        sources: list[dict[str, str]] | None = None,
        search_queries: list[str] | None = None,
    ):
        obj = super().__new__(cls, text)
        obj.text = text
        obj.speech_text = speech_text if speech_text is not None else text
        obj.sources = sources or []
        obj.search_queries = search_queries or []
        return obj


class BaseLLM(ABC):
    @abstractmethod
    async def complete(self, messages: list[dict[str, Any]], *, max_tokens: int = 1536) -> LLMResponse:
        ...


class MockLLM(BaseLLM):
    """Useful offline conversational fallback that never makes a network call."""

    async def complete(self, messages: list[dict[str, Any]], *, max_tokens: int = 1536) -> LLMResponse:
        await asyncio.sleep(0.05)
        user_text = next((m.get("content", "") for m in reversed(messages)
                          if m.get("role") == "user"), "")
        text = str(user_text).strip()
        lowered = text.lower()
        if not text:
            reply = "I didn't catch that. Could you say it again?"
        elif any(token in lowered for token in ("how are you", "are you okay", "how's it going")):
            reply = "I'm doing well and ready to help. What would you like to work on?"
        elif any(token in lowered for token in ("your purpose", "why were you made", "what is karen")):
            reply = "I'm K.A.R.E.N., a voice assistant for your Mac. I can answer simple questions offline, speak replies, and help you explore the orb."
        elif any(token in lowered for token in ("goodbye", "bye karen", "see you")):
            reply = "Goodbye! I'll be here when you need me."
        elif "weather" in lowered:
            reply = "I can't check live weather while offline. Add a Gemini API key in Settings to enable live web queries."
        elif any(token in lowered for token in ("artificial intelligence", "what is ai", "explain ai", "about ai")):
            reply = "Artificial intelligence refers to computer systems designed to emulate human cognitive functions, such as learning, pattern recognition, problem-solving, and natural language understanding. For example, machine learning models analyze large datasets to forecast trends, computer vision enables facial recognition and medical imaging analysis, and deep neural networks power voice assistants and autonomous driving systems, sir."
        else:
            reply = "I can help with common questions and commands offline. Add a Gemini API key in Settings for full online assistance."
        return LLMResponse(reply, speech_text=reply)


class GeminiLLM(BaseLLM):
    """Google Gemini client using the official REST API (v1beta).

    Uses gemini-3.8-flash by default with native Google Search grounding.
    """

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_GEMINI_MODEL,
        grounding: bool = True,
        client: httpx.AsyncClient | None = None,
    ):
        clean_key = api_key.strip()
        if not clean_key:
            raise ValueError("Gemini API key cannot be empty.")
        self.api_key = clean_key
        self.model = model.strip() or DEFAULT_GEMINI_MODEL
        self.grounding = grounding
        self._client = client

    def _convert_messages(self, messages: list[dict[str, Any]]) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
        """Maps OpenAI/Karen conversation format to Gemini API format.

        - Extracts system messages into a top-level system_instruction block.
        - Maps 'assistant' role to Gemini's 'model' role.
        - Merges consecutive messages with the same role.
        - Ensures the content sequence begins with a 'user' turn.
        """
        system_prompts: list[str] = []
        conversation_turns: list[dict[str, Any]] = []

        for msg in messages:
            role = str(msg.get("role", "")).strip().lower()
            content = str(msg.get("content", "")).strip()
            if not content:
                continue

            if role == "system":
                system_prompts.append(content)
            elif role in ("assistant", "model"):
                conversation_turns.append({"role": "model", "parts": [{"text": content}]})
            else:  # default to "user"
                conversation_turns.append({"role": "user", "parts": [{"text": content}]})

        # Top-level system_instruction
        system_instruction: dict[str, Any] | None = None
        if system_prompts:
            system_instruction = {"parts": [{"text": "\n\n".join(system_prompts)}]}

        # Consolidate consecutive turns with the same role
        consolidated: list[dict[str, Any]] = []
        for turn in conversation_turns:
            if consolidated and consolidated[-1]["role"] == turn["role"]:
                prev_text = consolidated[-1]["parts"][0]["text"]
                curr_text = turn["parts"][0]["text"]
                consolidated[-1]["parts"][0]["text"] = f"{prev_text}\n{curr_text}"
            else:
                consolidated.append(turn)

        # Gemini requires contents to start with role 'user'
        if consolidated and consolidated[0]["role"] != "user":
            consolidated.insert(0, {"role": "user", "parts": [{"text": "Hello."}]})

        return system_instruction, consolidated

    async def complete(self, messages: list[dict[str, Any]], *, max_tokens: int = 1536) -> LLMResponse:
        system_instruction, contents = self._convert_messages(messages)
        if not contents:
            return LLMResponse("How can I assist you, sir?", speech_text="How can I assist you, sir?")

        body: dict[str, Any] = {
            "contents": contents,
            "generationConfig": {
                "maxOutputTokens": max_tokens,
                "temperature": 0.7,
                "topP": 0.95,
            },
        }

        if system_instruction:
            body["system_instruction"] = system_instruction

        if self.grounding:
            # Official Google Search grounding tool specification
            body["tools"] = [{"google_search": {}}]

        headers = {
            "Content-Type": "application/json",
            "x-goog-api-key": self.api_key,
        }

        owns_client = self._client is None
        client = self._client or httpx.AsyncClient(http2=False, timeout=httpx.Timeout(10.0, connect=3.0))

        # Models to try: primary model first, followed by fallbacks if high demand occurs
        models_to_try = [self.model]
        for fallback in FALLBACK_GEMINI_MODELS:
            if fallback not in models_to_try:
                models_to_try.append(fallback)

        last_error = ""

        try:
            for idx, current_model in enumerate(models_to_try):
                url = f"https://generativelanguage.googleapis.com/v1beta/models/{current_model}:generateContent"
                has_fallback = idx < len(models_to_try) - 1

                try:
                    resp = await client.post(
                        url,
                        headers=headers,
                        params={"key": self.api_key},
                        json=body,
                        timeout=8.0,
                    )

                    # If Google Search grounding specifically hits rate limits / quota (429),
                    # retry the request without grounding so the user still receives an answer.
                    if resp.status_code == 429 and "tools" in body:
                        print(f"[GeminiLLM] Grounding quota exceeded; retrying {current_model} without search tool...")
                        self.grounding = False
                        body.pop("tools", None)
                        resp = await client.post(
                            url,
                            headers=headers,
                            params={"key": self.api_key},
                            json=body,
                            timeout=8.0,
                        )

                except httpx.TimeoutException:
                    if has_fallback:
                        last_error = f"Model {current_model} timed out."
                        print(f"[GeminiLLM] {last_error} Falling back to next model...")
                        continue
                    raise

                # If model is experiencing temporary 503 high demand spikes, try next fallback model
                if resp.status_code == 503:
                    last_error = f"Model {current_model} is experiencing high demand (503)."
                    print(f"[GeminiLLM] {last_error} Checking next model...")
                    continue

                # If model returned 429 (e.g. daily free tier request limit for this specific model), try fallback
                if resp.status_code == 429:
                    if has_fallback:
                        last_error = f"Model {current_model} quota or rate limit exceeded (429)."
                        print(f"[GeminiLLM] {last_error} Checking next model...")
                        continue
                    raise RuntimeError("Gemini rate limit or daily quota exceeded. Please check your plan or try again later.")

                if resp.status_code in (401, 403):
                    raise RuntimeError("Gemini API key is invalid or lacks required permissions. Check your key in Settings.")
                elif resp.status_code == 400:
                    err_text = ""
                    try:
                        err_json = resp.json()
                        err_text = err_json.get("error", {}).get("message", "")
                    except Exception:
                        pass
                    msg = f": {err_text}" if err_text else ""
                    raise RuntimeError(f"Gemini API bad request (HTTP 400){msg}")
                elif resp.status_code >= 500:
                    raise RuntimeError(f"Gemini service unavailable (HTTP {resp.status_code}). Please try again shortly.")

                resp.raise_for_status()
                payload = resp.json()

                candidates = payload.get("candidates", [])
                if not candidates:
                    raise RuntimeError("Gemini returned an empty response.")

                first_candidate = candidates[0]
                parts = first_candidate.get("content", {}).get("parts", [])
                raw_text = "".join(p.get("text", "") for p in parts if isinstance(p, dict) and "text" in p).strip()
                if not raw_text:
                    raw_text = "I received no response text from Gemini."

                # Extract search grounding metadata and citations if present
                grounding_meta = first_candidate.get("groundingMetadata") or {}
                grounding_chunks = grounding_meta.get("groundingChunks") or []
                search_queries = grounding_meta.get("webSearchQueries") or []

                sources: list[dict[str, str]] = []
                seen_urls: set[str] = set()
                for chunk in grounding_chunks:
                    web = chunk.get("web") if isinstance(chunk, dict) else None
                    if not web:
                        continue
                    uri = str(web.get("uri", "")).strip()
                    title = str(web.get("title", "")).strip() or "Source"
                    if uri and uri.startswith("http") and uri not in seen_urls:
                        seen_urls.add(uri)
                        sources.append({"title": title, "url": uri})

                # Spoken text is conversational without reading raw URLs
                speech_text = raw_text

                # Display text appends formatted citations when web search grounding was used
                if sources:
                    source_lines = [f"• {s['title']} ({s['url']})" for s in sources[:5]]
                    display_text = f"{raw_text}\n\nSources:\n" + "\n".join(source_lines)
                else:
                    display_text = raw_text

                return LLMResponse(
                    text=display_text,
                    speech_text=speech_text,
                    sources=sources,
                    search_queries=search_queries,
                )

            # If all models returned 503
            raise RuntimeError(f"Google Gemini service is temporarily unavailable due to high demand: {last_error}")

        except httpx.TimeoutException as exc:
            raise RuntimeError("Gemini request timed out. Please check your internet connection.") from exc
        except httpx.ConnectError as exc:
            raise RuntimeError("Could not connect to Gemini API. Check your internet connection.") from exc
        except httpx.HTTPStatusError as exc:
            raise RuntimeError(f"Gemini HTTP {exc.response.status_code} error.") from exc
        finally:
            if owns_client:
                await client.aclose()


def build_llm() -> BaseLLM:
    """Factory — reads provider and keys from environment.

    Supported providers:
    - 'gemini' (default when a Gemini key is present)
    - 'mock' (offline mode)
    """
    api_key = (
        os.environ.get("KAREN_GEMINI_KEY")
        or os.environ.get("KAREN_LLM_KEY")
        or os.environ.get("GEMINI_API_KEY", "")
    ).strip()

    provider = os.environ.get("KAREN_LLM_PROVIDER", "").strip().lower()

    # If provider is explicitly mock, or no key exists and no provider is specified:
    if provider == "mock" or (not provider and not api_key):
        print("[llm] Using offline MockLLM")
        return MockLLM()

    # If provider is set to gemini, or an api_key exists:
    if provider == "gemini" or api_key:
        if not api_key:
            raise RuntimeError(
                "Gemini provider was selected, but no API key was found in Keychain or environment."
            )
        model = os.environ.get("KAREN_GEMINI_MODEL", DEFAULT_GEMINI_MODEL).strip()
        grounding_str = os.environ.get("KAREN_GEMINI_GROUNDING", "false").strip().lower()
        grounding = grounding_str in ("true", "1", "yes")
        print(f"[llm] Initialized GeminiLLM with model='{model}', grounding={grounding}")
        return GeminiLLM(api_key=api_key, model=model, grounding=grounding)

    # Any unknown provider
    raise RuntimeError(f"Unknown LLM provider '{provider}'. Please use 'gemini' or 'mock'.")
