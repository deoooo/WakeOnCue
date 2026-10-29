from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts.generate_realtime_pairing import load_token, pairing_payload


class GenerateRealtimePairingTest(unittest.TestCase):
    def test_payload_matches_ios_pairing_contract(self) -> None:
        payload = json.loads(pairing_payload("https://gateway.example.com", "secret-token"))
        self.assertEqual(payload["type"], "wakeoncue.realtime-gateway")
        self.assertEqual(payload["version"], 1)
        self.assertEqual(payload["gateway_url"], "https://gateway.example.com")
        self.assertEqual(payload["gateway_token"], "secret-token")

    def test_rejects_invalid_scheme(self) -> None:
        with self.assertRaisesRegex(ValueError, "HTTP"):
            pairing_payload("file:///tmp/gateway", "secret-token")

    def test_rejects_missing_environment_token(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "missing"):
                load_token(environment_name="WAKEONCUE_REALTIME_API_TOKEN", token_file=None)

    def test_reads_token_from_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            token_file = Path(directory) / "token"
            token_file.write_text("file-secret\n", encoding="utf-8")
            self.assertEqual(
                load_token(environment_name=None, token_file=token_file),
                "file-secret",
            )


if __name__ == "__main__":
    unittest.main()
