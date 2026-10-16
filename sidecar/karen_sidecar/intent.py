"""Lightweight classification for local tools and the existing chat fallback."""

from __future__ import annotations

import re
from enum import StrEnum


class Intent(StrEnum):
    MATH = "mathematical calculation"
    LOGIC = "logical expression"
    SEARCH = "internet search request"
    APP = "application command"
    PROGRAMMING = "programming or technical question"
    CONVERSATION = "conversational command"
    KNOWLEDGE = "general knowledge question"
    UNSUPPORTED = "unsupported or ambiguous request"


_SEARCH = re.compile(r"\b(search(?:\s+(?:the\s+)?(?:internet|web|brave|google)|\s+for\b)|look up online|find online|on the internet|latest|current|recent news|today's news|current price)\b", re.I)
_LOGIC = re.compile(r"\b(?:truth table|logical|logic|xor|nand|nor|implies|equivalent to|greater than|less than|equal to|not equal to)\b|\b(?:true|false)\b\s+(?:and|or|xor|nand|nor)\b|\bnot\s+(?:true|false)\b|(?:==|!=|>=|<=|(?<!\*)>(?!>)|(?<!<)<)", re.I)
_MATH = re.compile(r"\b(?:calculate|compute|work out|arithmetic|plus|addition|add|added|minus|subtraction|subtract|subtracted|take away|less|times|multiply|multiplication|multiplied|product|divided|division|divide|quotient|over|slash|modulo|remainder|square root|cube root|factorial|percentage|percent of|gcd|lcm|sine|cosine|tangent|logarithm|mean|median|mode|prime factor)\b|\d\s*(?:\+|\*|/|%|\*\*|//|-)\s*\d", re.I)
_APP = re.compile(r"\b(?:open|launch|start)\s+(?:the\s+)?[a-z]", re.I)
_CONVERSATION = re.compile(r"\b(?:hello|hi|hey|good morning|good afternoon|good evening|thank you|thanks|goodbye|bye|how are you)\b", re.I)
_PROGRAMMING = re.compile(r"\b(?:python|swift|programming|code|compiler|debug|algorithm|api|database|software|function|class|variable)\b", re.I)
_AMBIGUOUS_MATH = re.compile(r"(?:\b(?:plus|minus|subtract|times|multiply|multiplied by|divided by|divide by|modulo|remainder|power of|raised to)\s*$|\b(?:calculate|compute|work out)\s*$|[+*/%^/]\s*$)", re.I)


def classify_intent(text: str) -> Intent:
    """Choose local math/logic/search tools before existing skills or chat fallback."""
    value = text.strip()
    if not value:
        return Intent.UNSUPPORTED
    if _AMBIGUOUS_MATH.search(value):
        return Intent.MATH
    if _SEARCH.search(value):
        return Intent.SEARCH
    if _LOGIC.search(value):
        return Intent.LOGIC
    if _MATH.search(value):
        return Intent.MATH
    if _APP.search(value):
        return Intent.APP
    if _PROGRAMMING.search(value):
        return Intent.PROGRAMMING
    if _CONVERSATION.search(value):
        return Intent.CONVERSATION
    return Intent.KNOWLEDGE
