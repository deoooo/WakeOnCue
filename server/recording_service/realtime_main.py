from __future__ import annotations

import os

from aiohttp import web

from .realtime_gateway import create_realtime_application


def main() -> None:
    host = os.environ.get("WAKEONCUE_REALTIME_HOST", "127.0.0.1")
    port = int(os.environ.get("WAKEONCUE_REALTIME_PORT", "8090"))
    token = os.environ.get("WAKEONCUE_REALTIME_API_TOKEN", "local-realtime-token")
    public_base_url = os.environ.get("WAKEONCUE_REALTIME_PUBLIC_BASE_URL")
    web.run_app(
        create_realtime_application(token, public_base_url),
        host=host,
        port=port,
        print=lambda message: print(f"WakeOnCue Realtime Gateway: {message}", flush=True),
    )


if __name__ == "__main__":
    main()
