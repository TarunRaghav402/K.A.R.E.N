"""Intent classification and Brave Search integration tests."""

import httpx
import pytest

from karen_sidecar.intent import Intent, classify_intent
from karen_sidecar.intelligence import answer_search_request
from karen_sidecar.web_search import SearchError, extract_search_query, parse_brave_results, search_web


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


def test_search_query_and_provider_extraction():
    assert extract_search_query("Search Brave for latest Python release") == ("brave", "latest Python release")
    assert extract_search_query("Search the internet for latest Python release") == (None, "latest Python release")
    assert extract_search_query("Search for artificial intelligence") == (None, "artificial intelligence")


def test_brave_response_parser_keeps_title_snippet_and_url():
    results = parse_brave_results({"web": {"results": [{
        "title": "Python Releases", "url": "https://python.org/downloads/", "description": "Current Python releases."
    }]}})
    assert len(results) == 1
    assert results[0].title == "Python Releases"
    assert results[0].description == "Current Python releases."


@pytest.mark.asyncio
async def test_search_refuses_to_claim_results_without_configuration(monkeypatch):
    monkeypatch.delenv("KAREN_SEARCH_PROVIDER", raising=False)
    monkeypatch.delenv("KAREN_BRAVE_API_KEY", raising=False)
    with pytest.raises(SearchError, match="not configured"):
        await search_web("latest Python", use_cache=False)


@pytest.mark.asyncio
async def test_search_uses_official_endpoint_and_token_header():
    async def responder(request: httpx.Request) -> httpx.Response:
        assert request.url.host == "api.search.brave.com"
        assert request.headers["X-Subscription-Token"] == "secret-test-token"
        assert request.url.params["q"] == "latest Python release"
        return httpx.Response(200, json={"web": {"results": [{
            "title": "Python Downloads", "url": "https://python.org/downloads/", "description": "Download Python."
        }]}})

    async with httpx.AsyncClient(transport=httpx.MockTransport(responder)) as client:
        results = await search_web("latest Python release", provider="brave",
                                   api_key="secret-test-token", client=client, use_cache=False)
    assert results[0].title == "Python Downloads"


@pytest.mark.asyncio
async def test_search_reply_keeps_sources_visible_and_speech_concise(monkeypatch):
    from karen_sidecar import intelligence

    async def fake_search(query, **kwargs):
        assert query == "latest Python release"
        return [parse_brave_results({"web": {"results": [{
            "title": "Python Downloads", "url": "https://python.org/downloads/", "description": "Python releases are listed here."
        }]}})[0]]

    monkeypatch.setattr(intelligence, "search_web", fake_search)
    context = {}
    reply = await answer_search_request("Search for latest Python release", context)
    assert "https://python.org/downloads/" in reply["reply"]
    assert "https://python.org/downloads/" not in reply["speech_text"]
    assert context["last_search"]["query"] == "latest Python release"
