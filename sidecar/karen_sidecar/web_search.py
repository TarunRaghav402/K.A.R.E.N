"""Optional Brave Search API client with bounded caching and safe failures."""

from __future__ import annotations

import asyncio
import os
import re
import time
from dataclasses import dataclass
from typing import Any

import httpx


ENDPOINT = "https://api.search.brave.com/res/v1/web/search"
CACHE_TTL_SECONDS = 300
CACHE_LIMIT = 64


class SearchError(RuntimeError):
    """Search is unconfigured, unavailable, or returned an invalid response."""


@dataclass(frozen=True)
class SearchResult:
    title: str
    url: str
    description: str


_cache: dict[tuple[str, str, str], tuple[float, list[SearchResult]]] = {}
_cache_lock = asyncio.Lock()


def _safe_source_url(value: str) -> bool:
    from urllib.parse import urlparse
    parsed = urlparse(value)
    return parsed.scheme in {"https", "http"} and bool(parsed.hostname) and not parsed.username and not parsed.password


def parse_brave_results(payload: dict[str, Any]) -> list[SearchResult]:
    web = payload.get("web")
    raw_results = web.get("results", []) if isinstance(web, dict) else []
    results: list[SearchResult] = []
    for item in raw_results:
        if not isinstance(item, dict):
            continue
        url = item.get("url")
        if not isinstance(url, str) or not _safe_source_url(url):
            continue
        title = item.get("title") if isinstance(item.get("title"), str) else "Search result"
        description = item.get("description") if isinstance(item.get("description"), str) else ""
        results.append(SearchResult(title=title.strip()[:240], url=url, description=description.strip()[:1200]))
        if len(results) >= 5:
            break
    return results


async def search_web(query: str, *, provider: str | None = None,
                     api_key: str | None = None, client: httpx.AsyncClient | None = None,
                     use_cache: bool = True) -> list[SearchResult]:
    selected_provider = (provider or os.environ.get("KAREN_SEARCH_PROVIDER", "")).strip().lower()
    if selected_provider != "brave":
        raise SearchError("Web search is not configured. Set KAREN_SEARCH_PROVIDER=brave and add a Brave API key.")
    token = api_key or os.environ.get("KAREN_BRAVE_API_KEY", "")
    if not token:
        raise SearchError("Brave web search needs a key in KAREN_BRAVE_API_KEY. No search was made.")
    query = query.strip()
    if not query or len(query) > 600:
        raise SearchError("Please give me a shorter search query.")

    country = os.environ.get("KAREN_SEARCH_COUNTRY", "IN").upper()[:2]
    language = os.environ.get("KAREN_SEARCH_LANG", "en").lower()[:8]
    key = (selected_provider, country + ":" + language, query.casefold())
    if use_cache:
        async with _cache_lock:
            cached = _cache.get(key)
            if cached and time.monotonic() - cached[0] < CACHE_TTL_SECONDS:
                return cached[1]
            if cached:
                _cache.pop(key, None)

    owns_client = client is None
    active_client = client or httpx.AsyncClient(timeout=httpx.Timeout(8.0, connect=3.0))
    try:
        response = await active_client.get(
            ENDPOINT,
            params={"q": query, "count": 5, "country": country, "search_lang": language},
            headers={"Accept": "application/json", "X-Subscription-Token": token},
        )
        response.raise_for_status()
        payload = response.json()
        if not isinstance(payload, dict):
            raise SearchError("The search provider returned an unreadable response.")
        results = parse_brave_results(payload)
        if not results:
            return []
        if use_cache:
            async with _cache_lock:
                _cache[key] = (time.monotonic(), results)
                while len(_cache) > CACHE_LIMIT:
                    oldest = min(_cache, key=lambda cache_key: _cache[cache_key][0])
                    _cache.pop(oldest, None)
        return results
    except httpx.TimeoutException as exc:
        raise SearchError("The web search timed out. Please try again in a moment.") from exc
    except httpx.HTTPStatusError as exc:
        status = exc.response.status_code
        if status == 401 or status == 403:
            message = "Brave rejected the API key. Check KAREN_BRAVE_API_KEY and your API plan."
        elif status == 429:
            message = "Brave search rate limit reached. Please try again later."
        else:
            message = f"Brave search returned HTTP {status}. Please try again later."
        raise SearchError(message) from exc
    except (httpx.HTTPError, ValueError) as exc:
        raise SearchError("I couldn’t connect to web search. Check the network and try again.") from exc
    finally:
        if owns_client:
            await active_client.aclose()


def extract_search_query(text: str) -> tuple[str | None, str]:
    value = re.sub(r"^(?:hey\s+)?(?:karen|assistant)[, ]+", "", text.strip(), flags=re.I)
    provider = None
    match = re.match(r"search\s+(brave|google)\s+(?:for\s+)?(.+)$", value, re.I)
    if match:
        provider = match.group(1).lower()
        query = match.group(2)
    else:
        query = re.sub(r"^(?:please\s+)?(?:search(?:\s+the)?\s+(?:internet|web)|search for|look up online|find online)(?:\s+for)?\s+", "", value, flags=re.I)
    query = re.sub(r"[?!.]+$", "", query).strip()
    if query.lower().endswith(" on brave"):
        query = query[:-9].strip()
        provider = "brave"
    elif query.lower().endswith(" on google"):
        query = query[:-10].strip()
        provider = "google"
    return provider, query
