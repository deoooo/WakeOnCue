#!/usr/bin/env python3
"""Create WakeOnCue realtime Gateway pairing JSON and a QR code without printing secrets."""

from __future__ import annotations

import argparse
from io import BytesIO
import json
import os
from pathlib import Path
import stat
from urllib.parse import urlsplit


PAIRING_TYPE = "wakeoncue.realtime-gateway"
PAIRING_VERSION = 1


def validate_gateway_url(value: str) -> str:
    url = value.strip()
    parsed = urlsplit(url)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("gateway URL must be an HTTP(S) base URL without credentials, query, or fragment")
    return url


def load_token(*, environment_name: str | None, token_file: Path | None) -> str:
    if token_file is not None:
        token = token_file.read_text(encoding="utf-8").strip()
    else:
        assert environment_name is not None
        token = os.environ.get(environment_name, "").strip()
    if not token:
        raise ValueError("gateway token is missing or empty")
    return token


def pairing_payload(gateway_url: str, gateway_token: str) -> str:
    return json.dumps(
        {
            "type": PAIRING_TYPE,
            "version": PAIRING_VERSION,
            "gateway_url": validate_gateway_url(gateway_url),
            "gateway_token": gateway_token,
        },
        ensure_ascii=False,
        separators=(",", ":"),
    )


def write_private_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(payload)
        output.write("\n")


def write_private_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(descriptor, "wb") as output:
        output.write(payload)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Public or private realtime Gateway base URL")
    token_source = parser.add_mutually_exclusive_group(required=True)
    token_source.add_argument(
        "--token-env",
        metavar="NAME",
        help="Read the Gateway token from environment variable NAME",
    )
    token_source.add_argument(
        "--token-file",
        type=Path,
        help="Read the Gateway token from a file",
    )
    parser.add_argument("--json-output", required=True, type=Path, help="Private JSON output path")
    parser.add_argument("--qr-output", required=True, type=Path, help="QR PNG output path")
    arguments = parser.parse_args()

    try:
        import qrcode

        token = load_token(environment_name=arguments.token_env, token_file=arguments.token_file)
        payload = pairing_payload(arguments.url, token)
        write_private_text(arguments.json_output, payload)
        image = qrcode.make(payload)
        encoded_image = BytesIO()
        image.save(encoded_image, format="PNG")
        write_private_bytes(arguments.qr_output, encoded_image.getvalue())
    except ModuleNotFoundError:
        parser.error("QR support is not installed; run pip install -e . in the server environment")
    except (OSError, ValueError) as error:
        parser.error(str(error))

    print(f"Pairing JSON written to {arguments.json_output}")
    print(f"Pairing QR written to {arguments.qr_output}")
    print("Treat both files as secrets and delete them after pairing.")


if __name__ == "__main__":
    main()
