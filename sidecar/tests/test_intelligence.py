"""Intent classification and search intelligence tests."""

import pytest
from karen_sidecar.intent import Intent, classify_intent
from karen_sidecar.intelligence import answer_search_request
from karen_sidecar.llm import MockLLM, GeminiLLM


@pytest.mark.parametrize(("utterance", "expected"), [
    ("Calculate 500 divided by 25", Intent.MATH),
    ("Subtract 10 from 30", Intent.MATH),
    ("Multiply 6 by 7", Intent.MATH),
    ("What is 6 slash 7?", Intent.MATH),
    ("Divide these two digits, 6 and 7", Intent.MATH),
    ("6 slash 7", Intent.MATH),
    ("Is 25 greater than 20?", Intent.LOGIC),
    ("Search the internet for the latest Python release", Intent.SEARCH),
    ("Search for artificial intelligence", Intent.SEARCH),
    ("Open Calculator", Intent.APP),
    ("What is a Python dictionary?", Intent.PROGRAMMING),
    ("Hello Karen", Intent.CONVERSATION),
    ("What is the capital of France?", Intent.KNOWLEDGE),
])
def test_intent_classification(utterance, expected):
    assert classify_intent(utterance) == expected


@pytest.mark.asyncio
async def test_offline_search_request_returns_gemini_setup_prompt():
    context = {"llm": MockLLM()}
    reply = await answer_search_request("Search for latest Mars rover news", context)
    assert "Gemini API key" in reply["reply"]
    assert "Settings" in reply["reply"]
    assert "Gemini API key" in reply["speech_text"]


@pytest.mark.asyncio
async def test_online_search_request_delegates_to_gemini():
    gemini = GeminiLLM(api_key="test-key")
    context = {"llm": gemini}
    reply = await answer_search_request("Search for latest Mars rover news", context)
    # Empty dict signals router to execute llm.complete() with Google Search grounding
    assert reply == {}
