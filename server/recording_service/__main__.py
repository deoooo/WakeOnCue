from __future__ import annotations

import os
from pathlib import Path

from .api import create_server


def main() -> None:
    host = os.environ.get("WAKEONCUE_HOST", "127.0.0.1")
    port = int(os.environ.get("WAKEONCUE_PORT", "8080"))
    data_directory = Path(os.environ.get("WAKEONCUE_DATA_DIR", ".local/recording-service"))
    api_token = os.environ.get("WAKEONCUE_API_TOKEN", "local-development-token")
    server = create_server(
        host=host,
        port=port,
        data_directory=data_directory,
        api_token=api_token,
        webhook_url=os.environ.get("WAKEONCUE_WEBHOOK_URL"),
        webhook_secret=os.environ.get("WAKEONCUE_WEBHOOK_SECRET"),
        public_base_url=os.environ.get("WAKEONCUE_PUBLIC_BASE_URL"),
        ffmpeg_binary=os.environ.get("WAKEONCUE_FFMPEG", "ffmpeg"),
    )
    print(f"WakeOnCue Recording Service listening at {server.service.public_base_url}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        server.service.database.close()


if __name__ == "__main__":
    main()
