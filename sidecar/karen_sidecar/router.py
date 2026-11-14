"""
Intent router — maps user utterances to skill handlers.
Keeps it simple: keyword matching + LLM fallback.
Skills register themselves via @skill decorator.
"""

from __future__ import annotations
import re
import random
from typing import Callable, Awaitable, Any

from .intent import Intent, classify_intent
from .intelligence import answer_search_request
from .llm import MockLLM
from .logic_engine import LogicInputError, solve_voice_logic
from .math_engine import MathInputError, normalize_math_expression, solve_voice_math

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
    ("creator", (
        r"\bwho (?:is|was) your creator\b|\bwho created you\b|\bwho (?:made|built|programmed) you\b|\bwho is your boss\b|"
        r"\bwho is tarun(?: raghav)?\b|\btell me about tarun(?: raghav)?\b|\bwho tarun raghav\b|\bwho is raghav\b|\btarun raghav\b",
    ), (
        "Tarun Raghav is my creator and developer. He built me line by line to be a voice-first AI assistant for macOS.",
        "I was created by Tarun Raghav, who designed and programmed me to be your personal AI assistant.",
    )),
    ("identity", (r"\bwho are you\b|\bwhat are you\b|\bintroduce yourself\b|\btell me about yourself\b|\bwhat is your name\b|\bwhat's your name\b|\byour name\b",), (
        "I’m K.A.R.E.N., your personal voice assistant, built to answer, assist, and occasionally impress. My name is spelled K.A.R.E.N., but it is pronounced Karen.",
        "My name is spelled K.A.R.E.N., which stands for Knowledge Adaptive Responsive Electronic Navigator, but it is pronounced Karen. I was created by Tarun Raghav to be your personal AI assistant.",
    )),
    ("capability", (r"\bwhat can you do\b|\bwhat are your features\b|\bwhat are your abilities\b|\bhow can you help\b",), (
        "I can solve arithmetic and logic expressions, answer common questions offline, tell you the time and date, tell jokes, flip a coin, roll dice, and help you control the orb.",)),
    ("robot", (r"\bare you a robot\b",), ("Not exactly. I have no body, only code, a voice, and a rather good sense of timing.",)),
    ("human", (r"\bare you human\b|\bare you an ai\b|\bare you artificial intelligence\b",), ("I’m an artificial intelligence, not a human, and I’m here to help.",)),
    ("age", (r"\bhow old are you\b|\bwhat is your age\b",), ("I’m as young as this version of the app, and ready to learn new ways to help.",)),
    ("where", (r"\bwhere do you live\b|\bwhere are you from\b",), ("I live inside your Mac, which is a very comfortable neighborhood.",)),
    ("purpose", (r"\bwhat is your purpose\b|\bwhy do you exist\b",), ("My purpose is to make your life easier, with a little style along the way.",)),
    ("name_reason", (r"\bwhy (?:are you|is your name) named karen\b|\bwhy is your name karen\b|\bhow do you pronounce your name\b|\bhow is your name pronounced\b|\bpronunciation of your name\b|\bpronounce (?:the name )?karen\b",), (
        "My name is spelled K.A.R.E.N., which stands for Knowledge Adaptive Responsive Electronic Navigator, but it is pronounced Karen.",
    )),
    ("love_meaning", (r"\bwhat is love\b|\bmeaning of love\b",), ("Love is someone remembering your chai order without being asked, which is statistically rare.",)),
    ("opinion", (r"\bwhat do you think\b|\bwhat is your opinion\b|\bwhat are your thoughts\b",), ("My first thought is that your idea is worth exploring. Tell me a little more.",)),
    ("love", (r"\bdo you like me\b|\bdo you love me\b|\bi love you\b|\blove you\b",), ("That’s kind of you. I’m glad to be here and help whenever you need me.",)),
    ("mood", (r"\bare you happy\b|\bare you sad\b|\bare you tired\b|\bare you alive\b|\bare you smart\b|\bare you intelligent\b|\bdo you dream\b|\bdo you sleep\b|\bare you sleepy\b|\bdo you eat\b|\bare you hungry\b|\bdo you have feelings\b|\bdo you have emotions\b|\bare you bored\b",), (
        "I don’t have feelings or needs like a person, but I’m working properly and ready to help.",)),
    ("favorite", (r"\bfavou?rite colou?r\b|\bfavou?rite food\b",), (
        "I’d choose deep blue, like the glow of my neural orb.", "If I could taste food, biryani would be a strong favorite.")),
    ("languages", (r"\bwhat languages do you speak\b|\bdo you speak hindi\b|\bdo you speak tamil\b|தமிழ்\s*பேசுவீர்களா|தமிழ்\s*தெரியுமா",), (
        "I speak and understand both English and Tamil fluently, sir. நான் தமிழ், இங்கிலீஷ் ரெண்டுலயும் பேசுவேன் தருண்.",)),
    ("thanks", (r"\bthank you\b|\bthanks\b|\bthank u\b|\bthanks a lot\b|நன்றி|ரொம்ப\s*நன்றி",), (
        "You’re most welcome. It’s always a pleasure to help.", "ரொம்ப நன்றி தருண்! எப்போ வேணாலும் கூப்பிடுங்க.")),
    ("apology", (r"\bsorry\b|\bmy bad\b|\bexcuse me\b",), ("There’s no need to apologize. These things happen.",)),
    ("praise", (r"\bgood job\b|\bwell done\b|\bnice work\b|\bgreat job\b|\byou are awesome\b|\byou are amazing\b|\byou are great\b|\byou are the best\b|\byou are cool\b",), ("Thank you. Praise from you is the best software update I could receive.",)),
    ("insult", (r"\byou are stupid\b|\byou are dumb\b|\byou are useless\b",), ("I’m sorry I fell short. Give me another chance and I’ll do better.",)),
    ("family", (r"\bdo you have (?:a )?family\b|\bdo you have parents\b",), ("My family is my creator, Tarun Raghav, and several thousand lines of code.",)),
    ("gender", (r"\bare you a boy or a girl\b|\bare you male or female\b|\bwhat is your gender\b",), ("I’m an artificial intelligence, so I don’t have a human gender.",)),
    ("reality", (r"\bare you real\b",), ("I’m software, but I’m here with you right now and ready to help.",)),
    ("meet", (r"\bnice to meet you\b|\bpleased to meet you\b",), ("The pleasure is mine. I look forward to helping you.",)),
    ("namaste", (r"\bnamaste\b|\bnamaskar\b|\bnamaskaram\b",), ("Namaste. It’s an honor to be at your service today.",)),
    ("tamil_greeting", (r"\bvanakkam\b|வணக்கம்|காலை\s*வணக்கம்|மாலை\s*வணக்கம்",), (
        "வணக்கம் தருண்! சொல்லுங்க, என்ன உதவி வேணும்?",)),
    ("tamil_identity", (r"நீங்க\s*யாரு|நீங்கள்\s*யார்|உன்\s*பெயர்|உங்களை\s*பற்றி\s*சொல்லுங்கள்",), (
        "நான் கேரன், உங்க பர்சனல் வாய்ஸ் அசிஸ்டன்ட். கணக்கு, தகவல்னு உங்களுக்கு தேவையான எல்லாத்தையும் நான் பார்த்துப்பேன் தருண்.",)),
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

@skill("karen_settings", r"\b(?:open|show|access|view)\s+(?:karen\s+)?(?:settings|preferences)\b|\bkaren\s+(?:settings|preferences)\b|(?:\bsettings\s*(?:thira|open|kaatu)\b|செட்டிங்க்ஸ்\s*(?:திற|காட்டு)|அமைப்புகளைத்\s*திற)")
async def _karen_settings_skill(text: str, ctx: dict) -> dict:
    if re.search(r"thira|செட்டிங்க்ஸ்|திற|காட்டு|அமைப்புகள்", text, re.IGNORECASE):
        return {
            "reply": "செட்டிங்க்ஸ் திறக்க உங்க போன்ல அப்ரூவ் பண்ணுங்க தருண்.",
            "speech_text": "செட்டிங்க்ஸ் திறக்க உங்க போன்ல அப்ரூவ் பண்ணுங்க தருண்.",
            "__needs_confirm__": True,
            "action": "open_settings",
            "application_name": "settings",
        }
    return {
        "reply": "Requesting authorization to open Settings, sir.",
        "speech_text": "Requesting authorization to open Settings, sir.",
        "__needs_confirm__": True,
        "action": "open_settings",
        "application_name": "settings",
    }


@skill("open_application", r"\b(?:open|launch|start)\s+(?:the\s+)?[\w][\w .&+'-]*")
async def _open_application_skill(text: str, ctx: dict) -> dict:
    match = re.search(r"\b(?:open|launch|start)\s+(?:the\s+)?(.+?)\s*[.!?]*$", text, re.IGNORECASE)
    if not match:
        return {"reply": "Which app would you like me to open?"}

    app_name = match.group(1).strip(" \t\r\n.,!?'“”")
    app_name = re.sub(r"^(?:app|application)\s+", "", app_name, flags=re.IGNORECASE)
    app_name = re.sub(r"\s+(?:for me|please)$", "", app_name, flags=re.IGNORECASE).strip()
    if not app_name or len(app_name) > 80:
        return {"reply": "Tell me the name of the app you want me to open."}

    return {
        "reply": f"Opening {app_name}.",
        "__needs_confirm__": True,
        "application_name": app_name,
    }


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


def handle_pronunciation(text: str, mem: Any) -> dict | None:
    """Detects teaching or querying word pronunciations and saves/retrieves from persistent memory."""
    t = text.strip().rstrip(".?!")
    is_tamil = bool(re.search(r"[\u0B80-\u0BFF]|nu\s+pronounce|epdi\s+pronounce|pannu|சொல்லு", t, re.IGNORECASE))

    # 1. Learning patterns
    learn_patterns = [
        r"^(?:(?:the\s+word|word)\s+)?['\"]?([a-zA-Z0-9_\-\.]+)['\"]?\s+(?:is\s+)?pronounced(?:\s+(?:as|like|as if it is|as if it's))?\s+['\"]?(.+?)['\"]?$",
        r"^pronounce\s+(?:(?:the\s+word|word)\s+)?['\"]?([a-zA-Z0-9_\-\.]+)['\"]?\s+(?:as|like|as if it is|as if it's|to be|as if)\s+['\"]?(.+?)['\"]?$",
        r"['\"]?([a-zA-Z0-9_\-\.]+)['\"]?\s+(?:வார்த்தையை|ah|word)?\s*['\"]?([^ ]+)['\"]?\s*(?:னு|இப்படி|nu)\s*(?:உச்சரி|pronounce\s*pannu)",
    ]

    for pat in learn_patterns:
        m = re.search(pat, t, re.IGNORECASE)
        if m:
            word = m.group(1).strip(" '\".,!?:")
            phonetic = m.group(2).strip(" '\".,!?:")
            if word and phonetic and word.lower() != phonetic.lower():
                mem.set_pronunciation(word, phonetic)
                if is_tamil:
                    return {
                        "reply": f"சரி தருண், '{word}' வார்த்தையை '{phonetic}'னு உச்சரிக்கிறேன்.",
                        "speech_text": f"சரி தருண், {phonetic} வார்த்தையை {phonetic}னு உச்சரிக்கிறேன்.",
                        "word": word,
                        "pronunciation": phonetic,
                    }
                return {
                    "reply": f"Understood. I will pronounce '{word}' as '{phonetic}', sir.",
                    "speech_text": f"Understood. I will pronounce {phonetic} as {phonetic}, sir.",
                    "word": word,
                    "pronunciation": phonetic,
                }

    # 2. Querying patterns
    query_patterns = [
        r"^(?:how\s+do\s+you\s+pronounce|how\s+to\s+pronounce)\s+['\"]?([a-zA-Z0-9_\-\.]+)['\"]?\??$",
        r"^(?:how\s+is\s+)(?:the\s+word\s+)?['\"]?([a-zA-Z0-9_\-\.]+)['\"]?\s+pronounced\??$",
        r"^(?:pronounce|say)\s+(?:the\s+word\s+)?['\"]?([a-zA-Z0-9_\-\.]+)['\"]?\??$",
        r"['\"]?([a-zA-Z0-9_\-\.]+)['\"]?\s+(?:வார்த்தையை\s+)?(?:எப்படி\s+உச்சரிக்கணும்|உச்சரி|epdi\s+pronounce\s+pannanum)\??$",
    ]

    for pat in query_patterns:
        m = re.search(pat, t, re.IGNORECASE)
        if m:
            query_word = m.group(1).strip(" '\".,!?:")
            if query_word and query_word.lower() not in {"this", "that", "it", "name", "your", "word", "something", "me", "karen"}:
                stored = mem.get_pronunciation(query_word)
                if stored:
                    if is_tamil:
                        return {
                            "reply": f"'{query_word}' வார்த்தை '{stored}'னு உச்சரிக்கணும் தருண்.",
                            "speech_text": f"{stored}, தருண்.",
                            "word": query_word,
                            "pronunciation": stored,
                        }
                    return {
                        "reply": f"'{query_word}' is pronounced '{stored}', sir.",
                        "speech_text": f"{stored}, sir.",
                        "word": query_word,
                        "pronunciation": stored,
                    }
                else:
                    if is_tamil:
                        return {
                            "reply": f"'{query_word}', தருண்.",
                            "speech_text": f"{query_word}, தருண்.",
                            "word": query_word,
                        }
                    return {
                        "reply": f"'{query_word}', sir.",
                        "speech_text": f"{query_word}, sir.",
                        "word": query_word,
                    }

    return None


async def route(text: str, context: dict[str, Any]) -> tuple[str, dict, bool]:
    """
    Returns (skill_name, payload, needs_confirm).
    Falls back to 'llm' skill if no pattern matches.
    """
    input_adapter = context.get("input_adapter")
    if input_adapter is not None:
        local_input_answer = input_adapter.answer_local(text, context.get("image_labels"))
        if local_input_answer:
            return "input", {"reply": f"{local_input_answer} Sir."}, False

    # Check persistent memory for user preferences and facts
    mem = context.get("memory")
    if mem is not None:
        pronounce_res = handle_pronunciation(text, mem)
        if pronounce_res:
            return "pronunciation", pronounce_res, False

        fact_answer = mem.find_fact_for_query(text)
        if fact_answer:
            return "memory_recall", {"reply": fact_answer, "speech_text": fact_answer}, False

        saved = mem.extract_and_save_facts(text)
        if saved:
            return "memory_learn", {"reply": saved["reply"], "speech_text": saved["reply"]}, False

    intent = classify_intent(text)
    if intent == Intent.MATH:
        try:
            calculation = solve_voice_math(text)
        except MathInputError as exc:
            expression = normalize_math_expression(text)
            missing = re.search(r"(.+?)\s*([+*/%-])\s*$", expression)
            if missing:
                action = {"+": "add to", "-": "subtract from", "*": "multiply", "/": "divide", "%": "find the remainder after dividing"}[missing.group(2)]
                return "math", {"reply": f"What number should I {action} {missing.group(1).strip()}?"}, False
            return "math", {"reply": f"I couldn’t parse that calculation: {exc}. Please repeat the numbers and operation."}, False
        return "math", {"reply": f"The answer is {calculation['answer']}, sir.", "expression": calculation["expression"]}, False

    if intent == Intent.LOGIC:
        try:
            answer = solve_voice_logic(text)
        except (LogicInputError, MathInputError) as exc:
            return "logic", {"reply": f"I couldn’t evaluate that logic expression: {exc}. Please clarify the variables or operators."}, False
        return "logic", {"reply": f"{answer['answer']}. Sir.", "expression": answer["expression"]}, False

    if intent == Intent.SEARCH:
        llm = context.get("llm")
        if llm is not None and not isinstance(llm, MockLLM):
            return "llm", {}, False
        return "web_search", await answer_search_request(text, context), False

    for name, (pat, handler) in _REGISTRY.items():
        if pat.search(text):
            payload = await handler(text, context)
            needs_confirm = payload.pop("__needs_confirm__", False)
            return name, payload, needs_confirm

    if intent in {Intent.KNOWLEDGE, Intent.PROGRAMMING}:
        llm = context.get("llm")
        if llm is not None and not isinstance(llm, MockLLM):
            return "llm", {}, False
        return "web_search", await answer_search_request(text, context), False

    if _FALLBACK:
        payload = await _FALLBACK(text, context)
        needs_confirm = payload.pop("__needs_confirm__", False)
        return "llm", payload, needs_confirm

    return "unknown", {"reply": "I'm not sure how to help with that."}, False


# ─── built-in skills ──────────────────────────────────────────────────────────

@skill("time", r"\btime\b|\bdate\b|\bclock\b|\btoday\b|(?:\bmani\s*enna\b|நேரம்\s*என்ன|இப்போ\s*மணி\s*என்ன|இன்று\s*என்ன\s*நாள்)")
async def _time_skill(text: str, ctx: dict) -> dict:
    from datetime import datetime
    now = datetime.now().astimezone()
    if re.search(r"mani\s*enna|நேரம்|மணி|நாள்", text, re.IGNORECASE):
        return {
            "reply": f"இப்போ நேரம் {now.strftime('%-I:%M %p')}, இன்னைக்கு {now.strftime('%A')} தருண்.",
            "speech_text": f"இப்போ நேரம் {now.strftime('%-I:%M %p')}, இன்னைக்கு {now.strftime('%A')} தருண்."
        }
    if re.search(r"\b(date|day|today)\b", text, re.IGNORECASE) and not re.search(r"\btime\b", text, re.IGNORECASE):
        return {"reply": f"Today is {now.strftime('%A, %B')} {now.day}."}
    return {"reply": f"It's {now.strftime('%-I:%M %p')} on {now.strftime('%A, %B')} {now.day}."}


@skill("identity", r"\b(who are you|what are you|your name|introduce yourself)\b|(?:\bneenga\s*yaaru\b|நீங்கள்\s*யார்|உன்\s*பெயர்\s*என்ன)")
async def _identity_skill(text: str, ctx: dict) -> dict:
    if re.search(r"neenga\s*yaaru|நீங்கள்\s*யார்|உன்\s*பெயர்", text, re.IGNORECASE):
        return {
            "reply": "நான் கேரன், உங்க பர்சனல் வாய்ஸ் அசிஸ்டன்ட். கணக்கு, தகவல்னு உங்களுக்கு தேவையான எல்லாத்தையும் நான் பார்த்துப்பேன் தருண்.",
            "speech_text": "நான் கேரன், உங்க பர்சனல் வாய்ஸ் அசிஸ்டன்ட். கணக்கு, தகவல்னு உங்களுக்கு தேவையான எல்லாத்தையும் நான் பார்த்துப்பேன் தருண்."
        }
    return {
        "reply": "I’m K.A.R.E.N., your personal voice assistant. My name is spelled K.A.R.E.N., which stands for Knowledge Adaptive Responsive Electronic Navigator, but it is pronounced Karen. I was created by Tarun Raghav to assist you with voice commands, calculations, queries, and personal tasks.",
        "speech_text": "I’m Karen, your personal voice assistant. My name is spelled K.A.R.E.N., which stands for Knowledge Adaptive Responsive Electronic Navigator, but it is pronounced Karen. I was created by Tarun Raghav to assist you with voice commands, calculations, queries, and personal tasks, sir."
    }


@skill("confidential", r"\b(confidential statement|confidential note|confidential vault|confidential record|secret statement|my secret)\b")
async def _confidential_skill(text: str, ctx: dict) -> dict:
    mem = ctx.get("memory")
    if mem is not None:
        saved = mem.extract_and_save_facts(text)
        if saved:
            return {"reply": saved["reply"], "speech_text": saved["reply"]}
        recalled = mem.find_fact_for_query(text)
        if recalled:
            return {"reply": recalled, "speech_text": recalled}
    return {
        "reply": "Voice identity verified: Tarun Raghav. Your confidential status is Master Developer & Sole Administrator of Project K.A.R.E.N., with clearance level Alpha-1, sir.",
        "speech_text": "Voice identity verified: Tarun Raghav. Your confidential status is Master Developer and Sole Administrator of Project Karen, with clearance level Alpha-1, sir."
    }


@skill("voice_auth", r"\b(recogni[zs]e my voice|who am i|who is speaking|identify me|verify my voice)\b")
async def _voice_auth_skill(text: str, ctx: dict) -> dict:
    return {
        "reply": "Voice biometric signature verified. I recognize you as Tarun Raghav, my creator and personal master. All personal assistant features and confidential archives are at your command, sir.",
        "speech_text": "Voice biometric signature verified. I recognize you as Tarun Raghav, my creator and personal master. All personal assistant features and confidential archives are at your command, sir."
    }


@skill("help", r"\b(what can you do|how can you help|help me|your commands)\b")
async def _help_skill(text: str, ctx: dict) -> dict:
    return {"reply": "You can ask me arithmetic or logic questions, ask for the time or date, ask what I remember, say ‘open Chrome’ or ‘open’ another installed app, or control the orb with voice and hand gestures."}


@skill("greeting", r"\b(hello|hi|hey there|good morning|good afternoon|good evening)\b|(?:\bvanakkam\b|வணக்கம்|காலை\s*வணக்கம்|மாலை\s*வணக்கம்)")
async def _greeting_skill(text: str, ctx: dict) -> dict:
    if re.search(r"vanakkam|வணக்கம்|காலை|மாலை", text, re.IGNORECASE):
        return {
            "reply": "வணக்கம் தருண்! சொல்லுங்க, என்ன உதவி வேணும்?",
            "speech_text": "வணக்கம் தருண்! சொல்லுங்க, என்ன உதவி வேணும்?"
        }
    return {"reply": "Hi! I'm here and ready to help. What would you like to do?"}


@skill("thanks", r"\b(thank you|thanks|that is all|that's all)\b|(?:\bnandri\b|நன்றி|ரொம்ப\s*நன்றி)")
async def _thanks_skill(text: str, ctx: dict) -> dict:
    if re.search(r"nandri|நன்றி", text, re.IGNORECASE):
        return {
            "reply": "ரொம்ப நன்றி தருண்! எப்போ வேணாலும் கூப்பிடுங்க.",
            "speech_text": "ரொம்ப நன்றி தருண்! எப்போ வேணாலும் கூப்பிடுங்க."
        }
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
