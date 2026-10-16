"""Orchestration helpers for search summaries and tool responses."""

from __future__ import annotations

from typing import Any

from .llm import MockLLM
from .web_search import SearchError, extract_search_query, search_web


async def answer_search_request(text: str, context: dict[str, Any]) -> dict[str, Any]:
    provider, query = extract_search_query(text)
    if provider == "google":
        return {"reply": "Google search is not configured. I currently support Brave Search; set KAREN_SEARCH_PROVIDER=brave and KAREN_BRAVE_API_KEY.",
                "speech_text": "Google search is not configured. I can use Brave Search once it has been configured."}
    try:
        results = await search_web(query, provider=provider)
    except SearchError as exc:
        return {"reply": str(exc), "speech_text": str(exc)}

    if not results:
        return {"reply": f"I searched for {query}, but the provider returned no results.",
                "speech_text": "I searched, but the provider returned no results."}

    source_context = "\n".join(
        f"[{index}] {item.title}\nURL: {item.url}\nSnippet: {item.description}"
        for index, item in enumerate(results, 1)
    )
    context["last_search"] = {"query": query, "sources": source_context}
    summary = " ".join(item.description for item in results[:3] if item.description)
    llm = context.get("llm")
    if llm is not None and not isinstance(llm, MockLLM):
        try:
            generated = await llm.complete([
                {"role": "system", "content": (
                    "Summarize only claims supported by these search snippets. Do not invent facts or "
                    "citations. Say when the snippets do not establish an answer. Use two concise sentences."
                )},
                {"role": "user", "content": f"Question: {query}\n\nSearch results:\n{source_context}"},
            ], max_tokens=160)
            if generated.strip():
                summary = generated.strip()
        except Exception as exc:  # Search results remain useful if the optional summarizer is down.
            print(f"[search] Summary generation failed: {type(exc).__name__}")

    if not summary:
        summary = f"I found {len(results)} relevant pages for {query}."
    citations = "\n".join(f"{index}. {item.title} — {item.url}" for index, item in enumerate(results, 1))
    speech = f"{summary.rstrip()} There are {len(results)} sources available in the results, sir."
    return {
        "reply": f"{summary}\n\nSources:\n{citations}",
        "speech_text": speech,
        "search_context": source_context,
    }
