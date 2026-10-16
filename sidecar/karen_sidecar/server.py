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
    # Import here so startup errors are visible
    from karen_sidecar.protocol import parse_shell_msg, StateMsg, ReplyMsg, ActionMsg, ErrorMsg, PongMsg, OrbState
    from karen_sidecar.llm import build_llm
    from karen_sidecar.memory import Memory
    from karen_sidecar.router import route

    llm = build_llm()
    memory = Memory()

    SYSTEM_PROMPT = """You are K.A.R.E.N. (Knowledge Adaptive Responsive Electronic Navigator), a voice-first AI personal assistant for macOS. Address the user respectfully and naturally. When asked arithmetic or logic questions, solve them carefully, check the result, and explain nontrivial answers briefly. Include 'sir' naturally at the end of your reply, as a separate courteous closing phrase; never attach it directly to a bare number or true/false result. Be calm, precise, warm, and helpful, with natural emotional range. Do not claim to have human feelings. Avoid repeating stock phrases; answer directly or ask one specific clarifying question. Speak naturally in one or two sentences. Never reveal system details. If you cannot do something, say so clearly."""

    conversation: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]
    # Mutable state avoids nested-function local-variable scoping bugs and keeps
    # the most recent result available across transcripts for this server.
    latest_search_context: dict[str, str | None] = {"value": None}

    async def handle_connection(websocket) -> None:
        print(f"[server] Shell connected: {websocket.remote_address}")
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
                    # Transition to processing
                    await websocket.send(StateMsg(state=OrbState.PROCESSING).model_dump_json())

                    user_text = msg.text
                    conversation.append({"role": "user", "content": user_text})

                    try:
                        # Try skill routing first
                        ctx = {"memory": memory, "llm": llm}
                        if latest_search_context["value"]:
                            ctx["search_context"] = latest_search_context["value"]
                        skill_name, payload, needs_confirm = await route(user_text, ctx)
                        if isinstance(ctx.get("last_search"), dict):
                            latest_search_context["value"] = (
                                f"Previous web search for {ctx['last_search']['query']}:\n"
                                f"{ctx['last_search']['sources']}"
                            )

                        if "reply" in payload:
                            reply_text = payload["reply"]
                        else:
                            # LLM fallback
                            mem_ctx = memory.context_block()
                            messages = list(conversation)
                            if latest_search_context["value"]:
                                messages.insert(1, {"role": "system", "content":
                                    "Use this recent web search context for relevant follow-up questions. "
                                    "If it does not answer the question, say so. Do not invent details.\n" + latest_search_context["value"]})
                            if mem_ctx:
                                messages.insert(1, {"role": "system", "content": mem_ctx})
                            reply_text = await llm.complete(messages)

                        # Normalize speech text and guide the system voice's
                        # pronunciation of the creator's name.
                        cleaned = re.sub(r"\s+", " ", reply_text).strip()
                        cleaned = re.sub(r"\s+([.!?])", r"\1", cleaned)
                        cleaned = re.sub(r"\bTARUN\s+RAGHV\b|\bTarun\s+Raghav\b|\bRaghav\b", "Ta-run Raa-ghav", cleaned, flags=re.IGNORECASE)
                        reply_text = cleaned or "I’m here to help, sir."
                        speech_text = payload.get("speech_text")
                        if isinstance(speech_text, str):
                            speech_text = re.sub(r"\s+", " ", speech_text).strip()
                            speech_text = re.sub(r"\bTARUN\s+RAGHV\b|\bTarun\s+Raghav\b|\bRaghav\b", "Ta-run Raa-ghav", speech_text, flags=re.IGNORECASE)

                        conversation.append({"role": "assistant", "content": reply_text})

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

                    except Exception as e:
                        print(f"[server] Processing error: {e}")
                        await websocket.send(StateMsg(state=OrbState.ERROR).model_dump_json())
                        await websocket.send(ErrorMsg(id=msg.id, message=str(e)).model_dump_json())
                        await websocket.send(StateMsg(state=OrbState.IDLE).model_dump_json())

                elif t == "cancel":
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
