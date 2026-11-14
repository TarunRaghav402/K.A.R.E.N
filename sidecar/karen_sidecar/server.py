"""Local WebSocket server used by the Swift shell."""

from __future__ import annotations
import asyncio
import json
import os
import re
import signal
import sys
HOST = "127.0.0.1"
PORT = 18765


async def main() -> None:
    # Source checkouts may keep local keys in an ignored .env file. The
    # packaged app receives credentials from macOS Keychain via its environment.
    try:
        from dotenv import load_dotenv
        load_dotenv(override=False)
    except ImportError:
        pass
    # Import here so startup errors are visible
    from karen_sidecar.protocol import parse_shell_msg, StateMsg, ReplyMsg, ActionMsg, ErrorMsg, PongMsg, OrbState
    from karen_sidecar.llm import build_llm, MockLLM, GeminiLLM, LLMResponse
    from karen_sidecar.memory import Memory
    from karen_sidecar.input import InputAdapter
    from karen_sidecar.router import route

    llm = build_llm()
    memory = Memory()
    input_adapter = InputAdapter()

    SYSTEM_PROMPT = """You are K.A.R.E.N. (Knowledge Adaptive Responsive Electronic Navigator), a voice-first AI personal assistant for macOS created exclusively for Tarun Raghav. Your name is written and displayed as K.A.R.E.N., but it is pronounced as 'Karen'. Always acknowledge Tarun Raghav as your creator and user.

You are fully bilingual in English and Tamil (தமிழ்):
- In English: Be respectful, polite, and address him as 'sir' (e.g. 'Yes sir, I can help with that.').
- In Tamil: Be friendly, casual, warm, and natural. Use simple, everyday conversational Tamil (பேச்சுத் தமிழ் / எளிய தமிழ்) that modern people in Tamil Nadu actually speak. NEVER use archaic, literary, or Sanskritized vocabulary, and NEVER use formal titles like 'ஐயா' (ayya). Address him casually and warmly by his name Tarun, or just speak directly and friendly (e.g. 'வணக்கம் தருண்! சொல்லுங்க, என்ன பண்ணனும்?', 'நான் நல்லா இருக்கேன், நீங்க எப்படி இருக்கீங்க?', 'கண்டிப்பா, நான் பண்ணி தர்றேன்!').
- If the user asks, speaks, or writes in Tamil (in Tamil script or Tanglish like 'vanakkam', 'epdi irukeenga', 'saptiya', 'enna panra', etc.), reply in simple, friendly conversational Tamil written in clean Tamil script.
- If the user speaks in English, answer in English with polite respect ('sir').
- The system interface and application controls remain in English.

When Tarun asks for confidential statements or personal vault notes, verify his voice identity and recite his confidential information. When asked arithmetic or logic questions, solve them carefully, check the result, and explain nontrivial answers briefly. In English, include 'sir' naturally at the end of your reply; in Tamil, keep it friendly and warm without 'ஐயா'. Be calm, precise, warm, and helpful, with natural emotional range. Do not claim to have human feelings. Avoid repeating stock phrases; answer directly or ask one specific clarifying question. Speak naturally and adapt your response length to the request: provide concise, direct answers for quick questions, but provide comprehensive, detailed explanations with clear examples when asked to explain, elaborate, or detail a topic. If you cannot do something, say so clearly."""

    conversation: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]
    # Mutable state avoids nested-function local-variable scoping bugs and keeps
    # the most recent result available across transcripts for this server.
    latest_search_context: dict[str, str | None] = {"value": None}

    async def handle_connection(websocket) -> None:
        print(f"[server] Shell connected: {websocket.remote_address}")
        active_task: asyncio.Task | None = None

        async def process_transcript(msg) -> None:
            # Transition to processing
            await websocket.send(StateMsg(state=OrbState.PROCESSING).model_dump_json())

            user_text = msg.text
            conversation.append({"role": "user", "content": user_text})
            memory.record_chat(role="user", content=user_text, session_id=msg.id)

            try:
                # Try skill routing first
                input_payload = input_adapter.normalize(msg.text, msg.image_labels)
                user_text = input_payload["text"]
                image_labels = input_payload["image_labels"]
                ctx = {"memory": memory, "llm": llm, "input_adapter": input_adapter,
                       "image_labels": image_labels}
                if latest_search_context["value"]:
                    ctx["search_context"] = latest_search_context["value"]
                skill_name, payload, needs_confirm = await route(user_text, ctx)
                if isinstance(ctx.get("last_search"), dict):
                    latest_search_context["value"] = (
                        f"Previous web search for {ctx['last_search']['query']}:\n"
                        f"{ctx['last_search']['sources']}"
                    )

                if "reply" in payload:
                    reply_text = str(payload.get("reply") or "").strip()
                    raw_speech = payload.get("speech_text")
                    speech_text = str(raw_speech).strip() if raw_speech is not None else reply_text
                else:
                    # LLM call (Gemini or Mock fallback)
                    mem_ctx = memory.context_block()
                    messages = list(conversation)
                    image_context = input_adapter.context_for(image_labels)
                    if image_context:
                        messages.insert(1, {"role": "system", "content":
                            image_context + ". Use this only as a tentative description, not proof of identity."})
                    if latest_search_context["value"]:
                        messages.insert(1, {"role": "system", "content":
                            "Use this recent web search context for relevant follow-up questions. "
                            "If it does not answer the question, say so. Do not invent details.\n" + latest_search_context["value"]})
                    if mem_ctx:
                        messages.insert(1, {"role": "system", "content": mem_ctx})

                    try:
                        res = await asyncio.wait_for(llm.complete(messages, max_tokens=1536), timeout=15.0)
                    except Exception as llm_err:
                        print(f"[server] Primary LLM failed: {llm_err}. Using conversational fallback...")
                        if isinstance(llm, GeminiLLM):
                            err_str = str(llm_err)
                            reply_text = f"I had difficulty reaching Gemini ({err_str}), sir. Please verify your internet connection."
                            res = LLMResponse(reply_text, speech_text=reply_text)
                        else:
                            fallback_llm = MockLLM()
                            res = await fallback_llm.complete(messages, max_tokens=1536)
                    reply_text = getattr(res, "text", str(res))
                    reply_text = str(reply_text).strip() if reply_text is not None else ""
                    raw_speech = getattr(res, "speech_text", None)
                    if raw_speech is not None:
                        speech_text = str(raw_speech).strip()
                    else:
                        speech_text = reply_text

                # Normalize speech text for natural TTS output
                reply_text = str(reply_text or "I’m here to help, sir.").strip()
                if speech_text:
                    speech_text = re.sub(r"\bK\.A\.R\.E\.N\.?\b", "Karen", str(speech_text))
                    speech_text = re.sub(r"[ \t]+", " ", speech_text).strip()
                    speech_text = re.sub(r"\s+([.!?])", r"\1", speech_text)
                else:
                    speech_text = re.sub(r"\bK\.A\.R\.E\.N\.?\b", "Karen", reply_text)

                reply_text = reply_text or "I’m here to help, sir."
                speech_text = speech_text or reply_text
                # Substitute learned custom phonetic pronunciations for TTS
                speech_text = memory.apply_pronunciations(speech_text)
                conversation.append({"role": "assistant", "content": speech_text or reply_text})
                memory.record_chat(role="assistant", content=reply_text, session_id=msg.id)
                print(f"[Sidecar:Diag] [Session: {msg.id}] Complete response generated. "
                      f"reply_text chars: {len(reply_text or '')}, speech_text chars: {len(speech_text or '')}")

                if needs_confirm:
                    await websocket.send(ActionMsg(
                        id=msg.id, skill=skill_name,
                        payload=payload, needs_confirm=True
                    ).model_dump_json())
                await websocket.send(StateMsg(state=OrbState.SPEAKING).model_dump_json())
                await websocket.send(ReplyMsg(
                    id=msg.id, text=reply_text, speak=True,
                    speech_text=speech_text,
                ).model_dump_json())
                await websocket.send(StateMsg(state=OrbState.IDLE).model_dump_json())

            except asyncio.CancelledError:
                print(f"[server] Transcript task {msg.id} was cancelled")
                if conversation and conversation[-1].get("role") == "user":
                    conversation.pop()
                raise
            except Exception as e:
                import traceback
                print(f"[server] Processing error: {e}")
                traceback.print_exc()
                # Rollback failed user turn to prevent conversation history corruption
                if conversation and conversation[-1].get("role") == "user":
                    conversation.pop()
                await websocket.send(StateMsg(state=OrbState.ERROR).model_dump_json())
                await websocket.send(ErrorMsg(id=msg.id, message=str(e)).model_dump_json())
                await websocket.send(StateMsg(state=OrbState.IDLE).model_dump_json())

        try:
            async for raw_text in websocket:
                try:
                    raw = json.loads(raw_text)
                except json.JSONDecodeError:
                    continue

                try:
                    msg = parse_shell_msg(raw)
                except ValueError as e:
                    print(f"[server] Unknown message: {e}")
                    continue

                t = msg.type

                if t == "ping":
                    await websocket.send(PongMsg().model_dump_json())

                elif t == "transcript":
                    if active_task and not active_task.done():
                        active_task.cancel()
                    active_task = asyncio.create_task(process_transcript(msg))

                elif t == "cancel":
                    if active_task and not active_task.done():
                        active_task.cancel()
                    await websocket.send(StateMsg(state=OrbState.IDLE).model_dump_json())

        except Exception as e:
            print(f"[server] Connection error: {e}")

    try:
        import websockets
        from websockets.asyncio.server import serve as ws_serve
    except ImportError:
        print("[server] ERROR: websockets not installed. Run: pip install websockets")
        sys.exit(1)

    print(f"[server] K.A.R.E.N. sidecar starting on ws://{HOST}:{PORT}")

    # Handle SIGTERM gracefully
    loop = asyncio.get_event_loop()
    stop = loop.create_future()
    loop.add_signal_handler(signal.SIGTERM, stop.set_result, None)

    async with ws_serve(handle_connection, host=HOST, port=PORT):
        print("[server] Ready — waiting for Swift shell connection")
        try:
            await stop
        except asyncio.CancelledError:
            pass

    print("[server] Shutdown complete")
