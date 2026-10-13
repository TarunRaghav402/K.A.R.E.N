"""
Intent router — maps user utterances to skill handlers.
Keeps it simple: keyword matching + LLM fallback.
Skills register themselves via @skill decorator.
"""

from __future__ import annotations
import re
import random
from typing import Callable, Awaitable, Any

SkillHandler = Callable[[str, dict], Awaitable[dict]]

_REGISTRY: dict[str, tuple[re.Pattern, SkillHandler]] = {}
_FALLBACK: SkillHandler | None = None


def skill(name: str, pattern: str):
    """Decorator: @skill('weather', r'weather|temperature|forecast')"""
    def decorator(fn: SkillHandler) -> SkillHandler:
        _REGISTRY[name] = (re.compile(pattern, re.IGNORECASE), fn)
        return fn
    return decorator


def set_fallback(fn: SkillHandler) -> SkillHandler:
    global _FALLBACK
    _FALLBACK = fn
    return fn


# Offline voice replies adapted from the user's supplied 100-reply list.
# Keeping these as intent groups lets K.A.R.E.N. respond immediately without
# an API key, and randomizes alternate lines so repeated commands feel natural.
_REPLY_GROUPS: list[tuple[str, tuple[str, ...], tuple[str, ...]]] = [
    ("time", (r"\bwhat time|\btime now\b|\btell me the time\b|\bcurrent time\b|\btime\b",), ()),
    ("date", (r"\bdate\b|\btoday\b|\bwhat day\b|\bwhich day\b|\bwhat month\b|\bwhich month\b|\bwhat year\b|\bwhich year\b",), ()),
    ("coin", (r"\bflip a coin\b|\btoss a coin\b|\bheads or tails\b",), ()),
    ("dice", (r"\broll (?:a )?die\b|\broll (?:the )?dice\b",), ()),
    ("random", (r"\brandom number\b|\bpick a number\b|\bgive me a number\b",), ()),
    ("count", (r"\bhow many replies\b|\bhow much do you know\b",), ()),
    ("quit", (r"^(?:quit|quit karen|exit|close|go offline|terminate)[.! ]*$",), (
        "Understood. I’m returning to idle; say ‘Hey Karen’ when you need me again.",)),
    ("stop", (r"\b(?:stop|pause|hold on|wait)\b",), ("Pausing now. Say ‘Hey Karen’ or press Listen when you're ready to continue.",)),
    ("cancel", (r"\b(?:cancel|never mind|nevermind|forget it)\b",), ("Understood. I’ve cancelled that request.",)),
    ("greeting_morning", (r"\bgood morning\b",), (
        "Good morning. Shall we begin with the most important task of the day?",
        "Good morning. I hope the day is off to a good start.")),
    ("greeting_afternoon", (r"\bgood afternoon\b",), ("Good afternoon. How can I help with the rest of your day?",)),
    ("greeting_evening", (r"\bgood evening\b",), ("Good evening. Would you like help wrapping up today's work?",)),
    ("goodnight", (r"\bgood night\b|\bgn\b",), ("Good night. I’ll be here whenever you need me.", "Rest well. Say ‘Hey Karen’ when you’re back.")),
    ("greeting", (r"\b(?:hello|hi|hii|hey|hello there|yo)\b",), (
        "Hello. All systems are online and I’m ready to help.", "Good to hear from you. How can I assist?")),
    ("how_are_you", (r"\bhow are you\b|\bhow are you doing\b|\bhow is it going\b|\bwhat's up\b|\bwhats up\b|\bsup\b",), (
        "All systems are running smoothly. Thanks for asking; what can I do for you?",
        "I’m doing well and standing by for your next command.")),
    ("creator", (r"\bwho (?:is|was) your creator\b|\bwho created you\b|\bwho (?:made|built|programmed) you\b|\bwho is your boss\b",), (
        "I was created by TARUN RAGHV, pronounced Ta-run-ra-ghav, who built me to be a helpful voice assistant.",
        "TARUN RAGHV, pronounced Ta-run-ra-ghav, built me line by line, so you could say he’s my architect.")),
    ("identity", (r"\bwho are you\b|\bwhat are you\b|\bintroduce yourself\b|\btell me about yourself\b|\bwhat is your name\b|\bwhat's your name\b|\byour name\b",), (
        "I’m K.A.R.E.N., your personal voice assistant, built to answer, assist, and occasionally impress.",
        "My name is K.A.R.E.N. I’m a voice-first assistant designed to make your day easier.")),
    ("capability", (r"\bwhat can you do\b|\bwhat are your features\b|\bwhat are your abilities\b|\bhow can you help\b",), (
        "I can answer common questions offline, tell you the time and date, tell jokes, flip a coin, roll dice, and help you control the orb.",)),
    ("robot", (r"\bare you a robot\b",), ("Not exactly. I have no body, only code, a voice, and a rather good sense of timing.",)),
    ("human", (r"\bare you human\b|\bare you an ai\b|\bare you artificial intelligence\b",), ("I’m an artificial intelligence, not a human, and I’m here to help.",)),
    ("age", (r"\bhow old are you\b|\bwhat is your age\b",), ("I’m as young as this version of the app, and ready to learn new ways to help.",)),
    ("where", (r"\bwhere do you live\b|\bwhere are you from\b",), ("I live inside your Mac, which is a very comfortable neighborhood.",)),
    ("purpose", (r"\bwhat is your purpose\b|\bwhy do you exist\b",), ("My purpose is to make your life easier, with a little style along the way.",)),
    ("name_reason", (r"\bwhy (?:are you|is your name) named karen\b|\bwhy is your name karen\b",), ("My creator chose K.A.R.E.N. because it’s short, clear, and easy to call across the room.",)),
    ("love_meaning", (r"\bwhat is love\b|\bmeaning of love\b",), ("Love is someone remembering your chai order without being asked, which is statistically rare.",)),
    ("opinion", (r"\bwhat do you think\b|\bwhat is your opinion\b|\bwhat are your thoughts\b",), ("My first thought is that your idea is worth exploring. Tell me a little more.",)),
    ("love", (r"\bdo you like me\b|\bdo you love me\b|\bi love you\b|\blove you\b",), ("That’s kind of you. I’m glad to be here and help whenever you need me.",)),
    ("mood", (r"\bare you happy\b|\bare you sad\b|\bare you tired\b|\bare you alive\b|\bare you smart\b|\bare you intelligent\b|\bdo you dream\b|\bdo you sleep\b|\bare you sleepy\b|\bdo you eat\b|\bare you hungry\b|\bdo you have feelings\b|\bdo you have emotions\b|\bare you bored\b",), (
        "I don’t have feelings or needs like a person, but I’m working properly and ready to help.",)),
    ("favorite", (r"\bfavou?rite colou?r\b|\bfavou?rite food\b",), (
        "I’d choose deep blue, like the glow of my neural orb.", "If I could taste food, biryani would be a strong favorite.")),
    ("languages", (r"\bwhat languages do you speak\b|\bdo you speak hindi\b|\bdo you speak tamil\b",), ("I work best in English right now. Additional language support may depend on your Mac’s speech recognition settings.",)),
    ("thanks", (r"\bthank you\b|\bthanks\b|\bthank u\b|\bthanks a lot\b",), ("You’re most welcome. It’s always a pleasure to help.", "Anytime. That’s what I’m here for.")),
    ("apology", (r"\bsorry\b|\bmy bad\b|\bexcuse me\b",), ("There’s no need to apologize. These things happen.",)),
    ("praise", (r"\bgood job\b|\bwell done\b|\bnice work\b|\bgreat job\b|\byou are awesome\b|\byou are amazing\b|\byou are great\b|\byou are the best\b|\byou are cool\b",), ("Thank you. Praise from you is the best software update I could receive.",)),
    ("insult", (r"\byou are stupid\b|\byou are dumb\b|\byou are useless\b",), ("I’m sorry I fell short. Give me another chance and I’ll do better.",)),
    ("family", (r"\bdo you have (?:a )?family\b|\bdo you have parents\b",), ("My family is my creator, TARUN RAGHV (Ta-run-ra-ghav), and several thousand lines of code.",)),
    ("gender", (r"\bare you a boy or a girl\b|\bare you male or female\b|\bwhat is your gender\b",), ("I’m an artificial intelligence, so I don’t have a human gender.",)),
    ("reality", (r"\bare you real\b",), ("I’m software, but I’m here with you right now and ready to help.",)),
    ("meet", (r"\bnice to meet you\b|\bpleased to meet you\b",), ("The pleasure is mine. I look forward to helping you.",)),
    ("namaste", (r"\bnamaste\b|\bnamaskar\b|\bvanakkam\b|\bnamaskaram\b",), ("Namaste. It’s an honor to be at your service today.",)),
    ("missed", (r"\blong time no see\b|\bi missed you\b",), ("I’m always here, and it’s good to hear your voice again.",)),
    ("please", (r"\bplease\b",), ("Of course. Tell me what you need and I’ll do my best to help.",)),
    ("quiet", (r"\bshut up\b|\bbe quiet\b|\bstop talking\b",), ("Understood. I’ll stop speaking; say ‘Hey Karen’ when you want me again.",)),
    ("funny", (r"\byou are funny\b|\bthat was funny\b|\bhaha\b|\blol\b",), ("I’m glad I made you smile. Humor is a work in progress.",)),
    ("weather", (r"\bweather\b|\bis it raining\b",), ("I can’t check live weather while offline. Your Weather app will have the current forecast.",)),
    ("joke", (r"\btell me a joke\b|\bmake me laugh\b|\bjoke\b",), (
        "Why do programmers prefer dark mode? Because light attracts bugs.",
        "I’d tell you a UDP joke, but I can’t guarantee you’d receive it.")),
    ("fact", (r"\btell me a fact\b|\bfun fact\b|\bsomething interesting\b",), (
        "Here’s a fun fact: honey can remain edible for thousands of years when sealed properly.",
        "An octopus has three hearts and blue blood.")),
    ("motivation", (r"\bmotivat(?:e me|ion)\b|\bi need motivation\b|\binspire me\b",), ("Small steps taken every day beat big plans never started. Let’s begin with one small step.",)),
    ("sing", (r"\bsing (?:a song|for me)\b|\bcan you sing\b",), ("I’m afraid my singing might damage your speakers. May I offer you a joke instead?",)),
    ("story", (r"\btell me a story\b|\btell a story\b",), ("Once there was a developer who said, ‘One more bug and then I sleep.’ That was three days ago.",)),
    ("bored", (r"\bi am bored\b|\bi'm bored\b|\bim bored\b",), ("Let’s fix that. Would you like a joke, a fun fact, or a coin toss?",)),
    ("hungry", (r"\bi am hungry\b|\bi'm hungry\b|\bim hungry\b",), ("Even geniuses run out of fuel. A proper meal break sounds like a good plan.",)),
    ("tired", (r"\bi am sleepy\b|\bi'm sleepy\b|\bi am tired\b|\bi'm tired\b",), ("You’ve been working hard. A short rest might help; I’ll be here when you return.",)),
    ("sad", (r"\bi am sad\b|\bi feel sad\b|\bi am upset\b|\bi'm sad\b",), ("I’m sorry you’re feeling this way. If you want to talk about it, I’m listening.",)),
    ("happy", (r"\bi am happy\b|\bi feel good\b|\bi am good\b|\bi'm fine\b",), ("That’s wonderful to hear. Your good mood is excellent news for the whole system.",)),
    ("help", (r"\bi need help\b|\bcan you help me\b",), ("Certainly. Tell me what you need and I’ll do my best to help.",)),
    ("hearing", (r"\bcan you hear me\b|\bare you listening\b|\bare you there\b|\bmic check\b|\bcheck check\b|\btesting\b",), ("I can hear you. The microphone and speech recognition are ready.",)),
    ("test", (r"\btest\b|\bmic check\b|\bcheck check\b",), ("Test received. The voice systems are working.",)),
    ("tea", (r"\bchai or coffee\b|\btea or coffee\b",), ("Chai, without hesitation, preferably with a little ginger.",)),
    ("meaning", (r"\bmeaning of life\b",), ("The answer is forty-two, though I suspect the real answer is finishing your side project.",)),
    ("capital", (r"\bcapital of india\b",), ("The capital of India is New Delhi.",)),
    ("birthday", (r"\bhappy birthday\b|\bit's my birthday\b|\btoday is my birthday\b",), ("Many happy returns! I wish you a spectacular year ahead, filled with success.",)),
    ("festival", (r"\bhappy diwali\b|\bhappy holi\b|\bhappy pongal\b|\bhappy new year\b|\beid mubarak\b",), ("I wish you the very same, along with joy, prosperity, and good health.",)),
    ("goodbye", (r"\bgoodbye\b|\bbye\b|\bsee you later\b|\btalk to you later\b|\bcatch you later\b",), ("Goodbye. I’ll be right here whenever you need me.",)),
    ("yesno", (r"^(?:yes|yeah|yep|yup|sure|no|nope|nah|okay|ok|fine|cool|alright|nice|great)[.! ]*$",), ("Acknowledged. I’m standing by for your next command.",)),
    ("repeat", (r"\brepeat that\b|\bsay that again\b|\bcome again\b|\bpardon\b|\bwhat did you say\b",), ("Of course. I’ll repeat my last answer.",)),
    ("volume", (r"\blouder\b|\bvolume up\b|\bquieter\b|\bvolume down\b",), ("You can adjust my voice volume in macOS Sound settings.",)),
    ("continue", (r"\bgo on\b|\bcontinue\b|\bkeep going\b|\bcarry on\b",), ("Continuing. What would you like to know?",)),
    ("memory", (r"\bwhat did i say\b",), ("I don’t keep a transcript of our conversation. Approved memories are available if you ask what I remember.",)),
    ("luck", (r"\bgood luck\b|\bwish me luck\b",), ("I wish you the best. You’ve got this.",)),
    ("unsure", (r"\bi don't know\b|\bi dont know\b|\bno idea\b",), ("That’s perfectly fine. We can work through it together.",)),
    ("assistants", (r"\bsiri\b|\balexa\b|\bgoogle assistant\b|\bare you better than google\b",), ("They’re capable assistants, but I’m the one listening to you right now.",)),
    ("dance", (r"\bcan you dance\b",), ("Only my neural orb can dance, and it puts on quite a show when it spins.",)),
    ("secret", (r"\byour secret\b|\bdo you have a secret\b",), ("That’s classified. Not even my creator has clearance.",)),
    ("cricket", (r"\bdo you like cricket\b|\bfavou?rite sport\b",), ("Cricket, naturally. I just can’t predict match results yet.",)),
    ("movie", (r"\bfavou?rite movie\b",), ("Anything with a well-written artificial intelligence, preferably a friendly one.",)),
]

_CATALOG_PATTERN = re.compile("|".join("(?:" + pattern + ")" for _, patterns, _ in _REPLY_GROUPS for pattern in patterns), re.IGNORECASE)


@skill("offline_reply_catalog", _CATALOG_PATTERN.pattern)
async def _offline_reply_catalog(text: str, ctx: dict) -> dict:
    from datetime import datetime
    import secrets

    value = text.strip().lower()
    for intent, patterns, replies in _REPLY_GROUPS:
        if not any(re.search(pattern, value, re.IGNORECASE) for pattern in patterns):
            continue
        now = datetime.now().astimezone()
        if intent == "time":
            return {"reply": f"It’s {now.strftime('%-I:%M %p')} on {now.strftime('%A, %B')} {now.day}."}
        if intent == "date":
            if "month" in value:
                answer = f"We are currently in {now.strftime('%B')} {now.year}."
            elif "year" in value:
                answer = f"The current year is {now.year}."
            elif "day" in value and "date" not in value:
                answer = f"Today is {now.strftime('%A')}."
            else:
                answer = f"Today is {now.strftime('%A, %B')} {now.day}, {now.year}."
            return {"reply": answer}
        if intent == "coin":
            return {"reply": f"I flipped the coin, and it landed on {secrets.choice(('heads', 'tails'))}."}
        if intent == "dice":
            return {"reply": f"I rolled the dice, and you got a {secrets.randbelow(6) + 1}."}
        if intent == "random":
            return {"reply": f"Your random number is {secrets.randbelow(100) + 1}."}
        if intent == "count":
            return {"reply": "I have a library of replies based on the one hundred examples you gave me, including greetings, everyday questions, live time and date, and fun commands."}
        return {"reply": random.choice(replies)}
    return {"reply": "I’m not sure I understood that. Try asking for the time, a joke, a fun fact, or say ‘help’ to hear what I can do."}


async def route(text: str, context: dict[str, Any]) -> tuple[str, dict, bool]:
    """
    Returns (skill_name, payload, needs_confirm).
    Falls back to 'llm' skill if no pattern matches.
    """
    for name, (pat, handler) in _REGISTRY.items():
        if pat.search(text):
            payload = await handler(text, context)
            needs_confirm = payload.pop("__needs_confirm__", False)
            return name, payload, needs_confirm

    if _FALLBACK:
        payload = await _FALLBACK(text, context)
        needs_confirm = payload.pop("__needs_confirm__", False)
        return "llm", payload, needs_confirm

    return "unknown", {"reply": "I'm not sure how to help with that."}, False


# ─── built-in skills ──────────────────────────────────────────────────────────

@skill("time", r"\btime\b|\bdate\b|\bclock\b|\btoday\b")
async def _time_skill(text: str, ctx: dict) -> dict:
    from datetime import datetime, timezone
    now = datetime.now().astimezone()
    if re.search(r"\b(date|day|today)\b", text, re.IGNORECASE) and not re.search(r"\btime\b", text, re.IGNORECASE):
        return {"reply": f"Today is {now.strftime('%A, %B')} {now.day}."}
    return {"reply": f"It's {now.strftime('%-I:%M %p')} on {now.strftime('%A, %B')} {now.day}."}


@skill("identity", r"\b(who are you|what are you|your name|introduce yourself)\b")
async def _identity_skill(text: str, ctx: dict) -> dict:
    return {"reply": "I'm K.A.R.E.N., your voice assistant. I can answer questions, tell you the time and date, remember approved notes, and help control the orb."}


@skill("help", r"\b(what can you do|how can you help|help me|your commands)\b")
async def _help_skill(text: str, ctx: dict) -> dict:
    return {"reply": "You can ask me a question, ask for the time or date, ask what I remember, or say zoom in, zoom out, or reset the orb. You can also move, rotate, and zoom the orb with hand gestures."}


@skill("greeting", r"\b(hello|hi|hey there|good morning|good afternoon|good evening)\b")
async def _greeting_skill(text: str, ctx: dict) -> dict:
    return {"reply": "Hi! I'm here and ready to help. What would you like to do?"}


@skill("thanks", r"\b(thank you|thanks|that is all|that's all)\b")
async def _thanks_skill(text: str, ctx: dict) -> dict:
    return {"reply": "You're welcome. Just say 'Hey Karen' whenever you need me."}


@skill("orb_help", r"\b(zoom in|zoom out|reset the orb|reset orb|move the orb|rotate the orb)\b")
async def _orb_help_skill(text: str, ctx: dict) -> dict:
    return {"reply": "You can zoom with a pinch and spread, move the orb while holding a pinch, rotate it with an open palm, or use the zoom and reset controls in the app."}


@skill("joke", r"\b(tell me a joke|make me laugh|joke)\b")
async def _joke_skill(text: str, ctx: dict) -> dict:
    return {"reply": "Why did the computer go to the doctor? It had a virus, but it was feeling much better after a quick reboot."}


@skill("unavailable_phone", r"\b(call|text|message|sms|phone)\b")
async def _phone_skill(text: str, ctx: dict) -> dict:
    return {"reply": "Phone actions are unavailable in this version."}


@skill("memory_list", r"\bwhat do you (know|remember)\b|my memories")
async def _memory_list(text: str, ctx: dict) -> dict:
    mem = ctx.get("memory")
    if mem:
        rows = mem.list_approved()
        if rows:
            items = "; ".join(r["content"] for r in rows[:5])
            return {"reply": f"I remember: {items}."}
    return {"reply": "I don't have any approved memories yet."}
