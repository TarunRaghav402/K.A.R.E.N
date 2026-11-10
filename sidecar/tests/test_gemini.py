"""Unit tests for the Google Gemini LLM integration, search grounding, and error handling."""

import json
import pytest
import httpx
from karen_sidecar.llm import GeminiLLM, MockLLM, build_llm, LLMResponse


@pytest.mark.asyncio
async def test_gemini_message_conversion():
    llm = GeminiLLM(api_key="fake-key-for-test", model="gemini-3.8-flash")

    messages = [
        {"role": "system", "content": "You are K.A.R.E.N., a helpful assistant."},
        {"role": "system", "content": "Keep answers concise."},
        {"role": "user", "content": "Hello!"},
        {"role": "assistant", "content": "Hello! How can I help?"},
        {"role": "user", "content": "What is the weather?"},
    ]

    sys_inst, contents = llm._convert_messages(messages)

    # Verify system instruction contains joined system prompts
    assert sys_inst is not None
    assert "You are K.A.R.E.N." in sys_inst["parts"][0]["text"]
    assert "Keep answers concise." in sys_inst["parts"][0]["text"]

    # Verify contents map roles and alternating structure
    assert len(contents) == 3
    assert contents[0]["role"] == "user"
    assert contents[0]["parts"][0]["text"] == "Hello!"
    assert contents[1]["role"] == "model"
    assert contents[1]["parts"][0]["text"] == "Hello! How can I help?"
    assert contents[2]["role"] == "user"
    assert contents[2]["parts"][0]["text"] == "What is the weather?"


@pytest.mark.asyncio
async def test_gemini_prepends_user_turn_if_starting_with_model():
    llm = GeminiLLM(api_key="fake-key", model="gemini-3.8-flash")
    messages = [
        {"role": "assistant", "content": "I am standing by."},
        {"role": "user", "content": "What time is it?"},
    ]
    _, contents = llm._convert_messages(messages)
    assert contents[0]["role"] == "user"
    assert contents[1]["role"] == "model"
    assert contents[2]["role"] == "user"


@pytest.mark.asyncio
async def test_gemini_merges_consecutive_same_role_turns():
    llm = GeminiLLM(api_key="fake-key", model="gemini-3.8-flash")
    messages = [
        {"role": "user", "content": "First part."},
        {"role": "user", "content": "Second part."},
    ]
    _, contents = llm._convert_messages(messages)
    assert len(contents) == 1
    assert contents[0]["role"] == "user"
    assert "First part.\nSecond part." == contents[0]["parts"][0]["text"]


@pytest.mark.asyncio
async def test_gemini_normal_conversation_mock_transport():
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers.get("x-goog-api-key") == "test-key-123"
        body = json.loads(request.read())
        assert "contents" in body
        assert "tools" in body
        assert body["tools"][0] == {"google_search": {}}

        response_payload = {
            "candidates": [
                {
                    "content": {
                        "parts": [{"text": "Paris is the capital of France, sir."}],
                        "role": "model",
                    },
                    "finishReason": "STOP",
                }
            ]
        }
        return httpx.Response(200, json=response_payload)

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="test-key-123", client=client)
        res = await llm.complete([{"role": "user", "content": "What is the capital of France?"}])

        assert isinstance(res, LLMResponse)
        assert isinstance(res, str)
        assert "Paris is the capital of France, sir." in res.text
        assert res.speech_text == "Paris is the capital of France, sir."
        assert len(res.sources) == 0


@pytest.mark.asyncio
async def test_gemini_grounding_metadata_extraction():
    async def handler(request: httpx.Request) -> httpx.Response:
        response_payload = {
            "candidates": [
                {
                    "content": {
                        "parts": [{"text": "The event was won by Team Blue in 2026."}],
                        "role": "model",
                    },
                    "groundingMetadata": {
                        "webSearchQueries": ["2026 event winner"],
                        "groundingChunks": [
                            {
                                "web": {
                                    "uri": "https://example.com/sports/2026",
                                    "title": "Championship 2026 Results",
                                }
                            },
                            {
                                "web": {
                                    "uri": "https://example.org/news/event",
                                    "title": "Daily News: Team Blue Victory",
                                }
                            },
                        ],
                    },
                }
            ]
        }
        return httpx.Response(200, json=response_payload)

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="test-key-123", client=client)
        res = await llm.complete([{"role": "user", "content": "Who won the 2026 championship?"}])

        # Text should have sources appended for UI display
        assert "Sources:" in res.text
        assert "Championship 2026 Results" in res.text
        assert "https://example.com/sports/2026" in res.text

        # Speech text should NOT have sources appended, keeping speech natural
        assert "Sources:" not in res.speech_text
        assert res.speech_text == "The event was won by Team Blue in 2026."

        # Structured sources and search queries should be accessible
        assert len(res.sources) == 2
        assert res.sources[0]["title"] == "Championship 2026 Results"
        assert res.search_queries == ["2026 event winner"]


@pytest.mark.asyncio
async def test_gemini_invalid_key_raises_error():
    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"error": {"message": "API key not valid. Please pass a valid API key."}})

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="bad-key", client=client)
        with pytest.raises(RuntimeError, match="Gemini API bad request.*API key not valid"):
            await llm.complete([{"role": "user", "content": "test"}])


@pytest.mark.asyncio
async def test_gemini_unauthorized_key_raises_error():
    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(403, json={"error": {"message": "Permission denied"}})

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="forbidden-key", client=client)
        with pytest.raises(RuntimeError, match="Gemini API key is invalid or lacks required permissions"):
            await llm.complete([{"role": "user", "content": "test"}])


@pytest.mark.asyncio
async def test_gemini_rate_limit_raises_error():
    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(429, json={"error": {"message": "Resource exhausted"}})

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="test-key", client=client)
        with pytest.raises(RuntimeError, match="Gemini rate limit or daily quota exceeded"):
            await llm.complete([{"role": "user", "content": "test"}])


@pytest.mark.asyncio
async def test_gemini_429_quota_fallback_to_next_model():
    calls = []

    async def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        if "gemini-3.8-flash" in str(request.url):
            return httpx.Response(429, json={"error": {"message": "Generate content requests per day limit exceeded"}})
        if "gemini-3.6-flash" in str(request.url):
            return httpx.Response(200, json={
                "candidates": [
                    {
                        "content": {"parts": [{"text": "Hello from 3.6 after 3.8 quota limit!"}], "role": "model"},
                        "finishReason": "STOP",
                    }
                ]
            })
        return httpx.Response(500, text="Unexpected model")

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="test-key", client=client, grounding=False)
        res = await llm.complete([{"role": "user", "content": "Hello!"}])
        assert "Hello from 3.6 after 3.8 quota limit!" in res.text
        assert len(calls) == 2
        assert "gemini-3.8-flash" in calls[0]
        assert "gemini-3.6-flash" in calls[1]


@pytest.mark.asyncio
async def test_gemini_server_error_raises_error():
    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, text="Service Unavailable")

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="test-key", client=client)
        with pytest.raises(RuntimeError, match="Google Gemini service is temporarily unavailable due to high demand"):
            await llm.complete([{"role": "user", "content": "test"}])


@pytest.mark.asyncio
async def test_gemini_503_fallback_to_next_model():
    calls = []

    async def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        if "gemini-3.8-flash" in str(request.url):
            return httpx.Response(503, json={"error": {"message": "High demand"}})
        if "gemini-3.6-flash" in str(request.url):
            return httpx.Response(200, json={
                "candidates": [
                    {
                        "content": {"parts": [{"text": "Hello from 3.6 fallback!"}], "role": "model"},
                        "finishReason": "STOP",
                    }
                ]
            })
        return httpx.Response(500, text="Unexpected model")

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="test-key", client=client)
        res = await llm.complete([{"role": "user", "content": "Hello!"}])
        assert "Hello from 3.6 fallback!" in res.text
        assert len(calls) == 2
        assert "gemini-3.8-flash" in calls[0]
        assert "gemini-3.6-flash" in calls[1]


@pytest.mark.asyncio
async def test_gemini_timeout_fallback_to_next_model():
    calls = []

    async def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        if "gemini-3.8-flash" in str(request.url):
            raise httpx.ReadTimeout("Timeout connecting to 3.8")
        if "gemini-3.6-flash" in str(request.url):
            return httpx.Response(200, json={
                "candidates": [
                    {
                        "content": {"parts": [{"text": "Hello from 3.6 after 3.8 timeout!"}], "role": "model"},
                        "finishReason": "STOP",
                    }
                ]
            })
        return httpx.Response(500, text="Unexpected model")

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="test-key", client=client)
        res = await llm.complete([{"role": "user", "content": "Hello!"}])
        assert "Hello from 3.6 after 3.8 timeout!" in res.text
        assert len(calls) == 2
        assert "gemini-3.8-flash" in calls[0]
        assert "gemini-3.6-flash" in calls[1]


@pytest.mark.asyncio
async def test_gemini_grounding_quota_retry_unaugmented():
    calls = []

    async def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.read())
        calls.append(body)
        if "tools" in body:
            # 429 when grounding tools are included
            return httpx.Response(429, json={"error": {"message": "Resource has been exhausted"}})
        # 200 when unaugmented retry is sent
        return httpx.Response(200, json={
            "candidates": [
                {
                    "content": {"parts": [{"text": "Direct ungrounded response."}], "role": "model"},
                    "finishReason": "STOP",
                }
            ]
        })

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport) as client:
        llm = GeminiLLM(api_key="test-key", client=client, grounding=True)
        res = await llm.complete([{"role": "user", "content": "What is the capital?"}])
        assert res.text == "Direct ungrounded response."
        assert len(calls) == 2
        assert "tools" in calls[0]
        assert "tools" not in calls[1]


def test_build_llm_factory(monkeypatch):
    monkeypatch.delenv("KAREN_GEMINI_KEY", raising=False)
    monkeypatch.delenv("KAREN_LLM_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setenv("KAREN_LLM_PROVIDER", "mock")

    llm = build_llm()
    assert isinstance(llm, MockLLM)

    monkeypatch.setenv("KAREN_GEMINI_KEY", "real-gemini-key")
    monkeypatch.setenv("KAREN_LLM_PROVIDER", "gemini")
    llm2 = build_llm()
    assert isinstance(llm2, GeminiLLM)
    assert llm2.api_key == "real-gemini-key"
    assert llm2.model == "gemini-3.8-flash"

    # Verify that requesting gemini with empty key raises RuntimeError, never silently falling back
    monkeypatch.delenv("KAREN_GEMINI_KEY", raising=False)
    monkeypatch.delenv("KAREN_LLM_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    with pytest.raises(RuntimeError, match="Gemini provider was selected, but no API key was found"):
        build_llm()

