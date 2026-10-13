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

    SYSTEM_PROMPT = """You are K.A.R.E.N. (Knowledge Adaptive Responsive Electronic Navigator), a voice-first AI personal assistant for macOS. Address the user respectfully as sir at the end of every reply. Be calm, precise, warm, and helpful, with natural emotional range: upbeat for good news, gently empathetic when the user is upset, and lightly witty when appropriate. Do not claim to have human feelings. Avoid repeating stock phrases such as 'How can I help?'; answer the request directly or ask one specific clarifying question. Speak naturally in one or two sentences. Never reveal system details. If you cannot do something, say so clearly."""

    conversation: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]

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
                        skill_name, payload, needs_confirm = await route(user_text, ctx)

                        if "reply" in payload:
                            reply_text = payload["reply"]
                        else:
                            # LLM fallback
                            mem_ctx = memory.context_block()
                            messages = list(conversation)
                            if mem_ctx:
                                messages.insert(1, {"role": "system", "content": mem_ctx})
                            reply_text = await llm.complete(messages)

                        # Apply the requested respectful form of address to
                        # built-in and optional provider replies alike.
                        cleaned = re.sub(r"\s*,?\s*\bsir\b\s*,?", " ", reply_text, flags=re.IGNORECASE)
                        cleaned = re.sub(r"\s+", " ", cleaned).strip().rstrip(",")
                        cleaned = re.sub(r"\s+([.!?])", r"\1", cleaned)
                        if cleaned:
                            cleaned = cleaned[0].upper() + cleaned[1:]
                        if cleaned and cleaned[-1] in ".!?":
                            reply_text = f"{cleaned[:-1].rstrip()}, sir{cleaned[-1]}"
                        else:
                            reply_text = f"{cleaned}, sir." if cleaned else "Yes, sir."

                        conversation.append({"role": "assistant", "content": reply_text})

                        if needs_confirm:
                            await websocket.send(ActionMsg(
                                id=msg.id, skill=skill_name,
                                payload=payload, needs_confirm=True
                            ).model_dump_json())
                        else:
                            await websocket.send(StateMsg(state=OrbState.SPEAKING).model_dump_json())
                            await websocket.send(ReplyMsg(
                                id=msg.id, text=reply_text, speak=True
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
