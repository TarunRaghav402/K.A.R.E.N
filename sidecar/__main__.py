"""
K.A.R.E.N. Python Sidecar
LLM orchestration, memory, skill routing.
Connects to the Swift shell via a localhost WebSocket.
"""

from karen_sidecar.server import main
import asyncio

if __name__ == "__main__":
    asyncio.run(main())
