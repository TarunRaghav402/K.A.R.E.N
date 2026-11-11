#!/usr/bin/env python3
"""Launcher for K.A.R.E.N. Remote Link Backend Relay Server."""

import sys
import uvicorn
from RemoteLink.Backend.config import settings

def main():
    print("=" * 60)
    print("  K.A.R.E.N. Remote Link — Backend Relay Server")
    print(f"  Listening on: http://{settings.host}:{settings.port}")
    print(f"  Database:     {settings.db_path}")
    print("=" * 60)
    uvicorn.run(
        "RemoteLink.Backend.server:app",
        host=settings.host,
        port=settings.port,
        reload=False,
        log_level="info",
    )

if __name__ == "__main__":
    main()

