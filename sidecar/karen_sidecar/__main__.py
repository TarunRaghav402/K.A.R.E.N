"""Run the K.A.R.E.N. sidecar server with ``python -m karen_sidecar``."""

import asyncio

from karen_sidecar.server import main


if __name__ == "__main__":
    asyncio.run(main())
