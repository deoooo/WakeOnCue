from __future__ import annotations

import hashlib
import hmac
import json
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from recording_service.api import create_server


class FakeS3Client:
    def __init__(self, objects: dict[tuple[str, str], tuple[bytes, dict[str, str], str]]) -> None:
        self.objects = objects

    def put_object(
        self,
        *,
        Bucket: str,
        Key: str,
        Body: bytes,
        ContentType: str,
        Metadata: dict[str, str],
    ) -> None:
        if Bucket == "unreachable":
            raise OSError("test endpoint refused the request")
        self.objects[(Bucket, Key)] = (bytes(Body), Metadata, ContentType)

    def head_object(self, *, Bucket: str, Key: str) -> dict[str, object]:
        body, metadata, _ = self.objects[(Bucket, Key)]
        return {"ContentLength": len(body), "Metadata": metadata}

    def delete_object(self, *, Bucket: str, Key: str) -> None:
        self.objects.pop((Bucket, Key), None)

    def upload_file(
        self,
        filename: str,
        bucket: str,
        key: str,
        ExtraArgs: dict[str, object],
    ) -> None:
        self.objects[(bucket, key)] = (
            Path(filename).read_bytes(),
            dict(ExtraArgs.get("Metadata", {})),
            str(ExtraArgs.get("ContentType", "application/octet-stream")),
        )

    def download_file(self, bucket: str, key: str, filename: str) -> None:
        Path(filename).write_bytes(self.objects[(bucket, key)][0])


class FakeS3Factory:
    def __init__(self) -> None:
        self.objects: dict[tuple[str, str], tuple[bytes, dict[str, str], str]] = {}

    def __call__(self, configuration: object) -> FakeS3Client:
        return FakeS3Client(self.objects)


class WebhookReceiver(BaseHTTPRequestHandler):
    requests: list[tuple[dict[str, str], bytes]] = []

    def do_POST(self) -> None:
        length = int(self.headers["Content-Length"])
        headers = {key.lower(): value for key, value in self.headers.items()}
        self.__class__.requests.append((headers, self.rfile.read(length)))
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:
        pass


class RecordingAPITest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.webhook_server = ThreadingHTTPServer(("127.0.0.1", 0), WebhookReceiver)
        cls.webhook_thread = threading.Thread(target=cls.webhook_server.serve_forever, daemon=True)
        cls.webhook_thread.start()
        webhook_url = f"http://127.0.0.1:{cls.webhook_server.server_port}/events"
        cls.server = create_server(
            "127.0.0.1",
            0,
            cls.root / "data",
            "test-token",
            webhook_url=webhook_url,
            webhook_secret="webhook-secret",
        )
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = cls.server.service.public_base_url
        cls.chunks = [cls._make_chunk(440), cls._make_chunk(660)]

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.server.service.database.close()
        cls.thread.join(timeout=5)
        cls.webhook_server.shutdown()
        cls.webhook_server.server_close()
        cls.webhook_thread.join(timeout=5)
        cls.temporary.cleanup()

    @classmethod
    def _make_chunk(cls, frequency: int) -> bytes:
        output = cls.root / f"{frequency}.m4a"
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                f"sine=frequency={frequency}:duration=0.35",
                "-ac",
                "1",
                "-c:a",
                "aac",
                "-b:a",
                "64k",
                "-y",
                str(output),
            ],
            check=True,
        )
        return output.read_bytes()

    def request(
        self,
        method: str,
        path: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
        authorized: bool = True,
        base_url: str | None = None,
    ) -> tuple[int, bytes, dict[str, str]]:
        request_headers = dict(headers or {})
        if authorized:
            request_headers["Authorization"] = "Bearer test-token"
        request = urllib.request.Request(
            f"{base_url or self.base_url}{path}",
            data=body,
            method=method,
            headers=request_headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.read(), dict(response.headers)
        except urllib.error.HTTPError as error:
            return error.code, error.read(), dict(error.headers)

    def test_complete_idempotent_recording_flow(self) -> None:
        WebhookReceiver.requests.clear()
        recording_id = "rec_integration"
        payload = json.dumps(
            {
                "id": recording_id,
                "created_at": "2026-08-23T00:00:00.000Z",
                "started_at": "2026-08-23T00:00:00.000Z",
                "device_model": "test",
                "app_version": "1",
                "metadata": {"room": "A"},
            }
        ).encode()
        status, _, _ = self.request(
            "POST", "/v1/recordings", payload, {"Content-Type": "application/json"}
        )
        self.assertEqual(status, 201)

        for action, expected_status in (
            ("pause", "PAUSED"),
            ("pause", "PAUSED"),
            ("resume", "RECORDING"),
            ("resume", "RECORDING"),
        ):
            status, body, _ = self.request(
                "POST", f"/v1/recordings/{recording_id}/{action}", b""
            )
            self.assertEqual(status, 200, body)
            self.assertEqual(json.loads(body)["status"], expected_status)

        for index, chunk in enumerate(self.chunks, start=1):
            checksum = hashlib.sha256(chunk).hexdigest()
            status, body, _ = self.request(
                "PUT",
                f"/v1/recordings/{recording_id}/chunks/{index}",
                chunk,
                {
                    "Content-Type": "audio/mp4",
                    "X-Chunk-Checksum": checksum,
                    "X-Chunk-Started-At": f"2026-08-23T00:00:0{index}.000Z",
                    "X-Chunk-Duration": "0.35",
                },
            )
            self.assertEqual(status, 200, body)
            self.assertFalse(json.loads(body)["duplicate"])

        first = self.chunks[0]
        status, body, _ = self.request(
            "PUT",
            f"/v1/recordings/{recording_id}/chunks/1",
            first,
            {
                "Content-Type": "audio/mp4",
                "X-Chunk-Checksum": hashlib.sha256(first).hexdigest(),
                "X-Chunk-Started-At": "2026-08-23T00:00:01.000Z",
                "X-Chunk-Duration": "0.35",
            },
        )
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["duplicate"])

        status, body, _ = self.request("POST", f"/v1/recordings/{recording_id}/finish", b"")
        self.assertEqual(status, 200, body)
        recording = json.loads(body)
        self.assertEqual(recording["status"], "COMPLETED")
        self.assertEqual(recording["chunk_count"], 2)
        self.assertTrue(recording["audio_available"])

        status, repeated_finish, _ = self.request(
            "POST", f"/v1/recordings/{recording_id}/finish", b""
        )
        self.assertEqual(status, 200, repeated_finish)
        self.assertEqual(json.loads(repeated_finish)["status"], "COMPLETED")

        status, body, _ = self.request("POST", f"/v1/recordings/{recording_id}/pause", b"")
        self.assertEqual(status, 409, body)

        extra = self.chunks[0]
        status, body, _ = self.request(
            "PUT",
            f"/v1/recordings/{recording_id}/chunks/3",
            extra,
            {
                "Content-Type": "audio/mp4",
                "X-Chunk-Checksum": hashlib.sha256(extra).hexdigest(),
                "X-Chunk-Started-At": "2026-08-23T00:00:03.000Z",
                "X-Chunk-Duration": "0.35",
            },
        )
        self.assertEqual(status, 409, body)

        status, audio, headers = self.request("GET", f"/v1/recordings/{recording_id}/audio")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "audio/mp4")
        self.assertIn(b"ftyp", audio[:64])

        merged = self.root / "merged.m4a"
        merged.write_bytes(audio)
        duration = float(
            subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(merged),
                ],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
        )
        self.assertGreater(duration, 0.6)

        self.assertEqual(len(WebhookReceiver.requests), 1)
        webhook_headers, webhook_body = WebhookReceiver.requests[0]
        webhook = json.loads(webhook_body)
        self.assertEqual(webhook["event"], "recording.finished")
        self.assertEqual(webhook["recording_id"], recording_id)
        self.assertTrue(webhook["audio_url"].endswith(f"/{recording_id}/audio"))
        timestamp = webhook_headers["x-wakeoncue-timestamp"]
        expected_signature = hmac.new(
            b"webhook-secret",
            timestamp.encode() + b"." + webhook_body,
            hashlib.sha256,
        ).hexdigest()
        self.assertEqual(
            webhook_headers["x-wakeoncue-signature"], f"sha256={expected_signature}"
        )

        status, body, _ = self.request("GET", "/v1/recordings?from=2026-08-01&to=2026-08-31")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["recordings"][0]["id"], recording_id)

    def test_concurrent_duplicate_upload_keeps_one_durable_chunk(self) -> None:
        recording_id = "rec_concurrent"
        payload = json.dumps({"id": recording_id}).encode()
        self.assertEqual(
            self.request("POST", "/v1/recordings", payload, {"Content-Type": "application/json"})[0],
            201,
        )
        chunk = self.chunks[0]
        headers = {
            "Content-Type": "audio/mp4",
            "X-Chunk-Checksum": hashlib.sha256(chunk).hexdigest(),
            "X-Chunk-Started-At": "2026-08-23T00:00:00.000Z",
            "X-Chunk-Duration": "0.35",
        }

        def upload() -> tuple[int, bytes, dict[str, str]]:
            return self.request(
                "PUT", f"/v1/recordings/{recording_id}/chunks/1", chunk, headers
            )

        with ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(lambda _: upload(), range(8)))

        self.assertTrue(all(status == 200 for status, _, _ in results))
        acknowledgements = [json.loads(body) for _, body, _ in results]
        self.assertEqual(sum(not ack["duplicate"] for ack in acknowledgements), 1)
        self.assertEqual(sum(ack["duplicate"] for ack in acknowledgements), 7)
        chunks = self.server.service.database.chunks(recording_id)
        self.assertEqual(len(chunks), 1)
        durable_path = Path(chunks[0]["path"])
        self.assertTrue(durable_path.is_file())

        durable_path.unlink()
        status, body, _ = upload()
        self.assertEqual(status, 200, body)
        self.assertTrue(json.loads(body)["duplicate"])
        self.assertTrue(durable_path.is_file())
        self.assertEqual(
            hashlib.sha256(durable_path.read_bytes()).hexdigest(),
            headers["X-Chunk-Checksum"],
        )

        status, body, _ = self.request("POST", f"/v1/recordings/{recording_id}/finish", b"")
        self.assertEqual(status, 200, body)
        self.assertEqual(json.loads(body)["status"], "COMPLETED")

    def test_rejects_gap_and_unauthorized_access(self) -> None:
        status, _, _ = self.request("GET", "/v1/recordings", authorized=False)
        self.assertEqual(status, 401)

        invalid_id = "rec_invalid_chunk"
        payload = json.dumps({"id": invalid_id}).encode()
        self.assertEqual(
            self.request("POST", "/v1/recordings", payload, {"Content-Type": "application/json"})[0],
            201,
        )
        invalid_chunk = self.chunks[0]
        status, body, _ = self.request(
            "PUT",
            f"/v1/recordings/{invalid_id}/chunks/1",
            invalid_chunk,
            {
                "X-Chunk-Checksum": hashlib.sha256(invalid_chunk).hexdigest(),
                "X-Chunk-Started-At": "2026-08-23T00:00:00.000Z",
                "X-Chunk-Duration": "nan",
            },
        )
        self.assertEqual(status, 400, body)
        self.assertEqual(json.loads(body)["error"], "invalid_duration")

        recording_id = "rec_gap"
        payload = json.dumps({"id": recording_id}).encode()
        self.assertEqual(
            self.request("POST", "/v1/recordings", payload, {"Content-Type": "application/json"})[0],
            201,
        )
        chunk = self.chunks[0]
        status, _, _ = self.request(
            "PUT",
            f"/v1/recordings/{recording_id}/chunks/2",
            chunk,
            {
                "X-Chunk-Checksum": hashlib.sha256(chunk).hexdigest(),
                "X-Chunk-Started-At": "2026-08-23T00:00:00.000Z",
                "X-Chunk-Duration": "0.35",
            },
        )
        self.assertEqual(status, 200)
        status, body, _ = self.request("POST", f"/v1/recordings/{recording_id}/finish", b"")
        self.assertEqual(status, 409)
        self.assertEqual(json.loads(body)["details"], [1])

    def test_persists_recording_and_chunk_across_service_restart(self) -> None:
        data_directory = self.root / "restart-data"
        recording_id = "rec_restart"
        chunk = self.chunks[0]
        chunk_headers = {
            "Content-Type": "audio/mp4",
            "X-Chunk-Checksum": hashlib.sha256(chunk).hexdigest(),
            "X-Chunk-Started-At": "2026-08-23T00:00:00.000Z",
            "X-Chunk-Duration": "0.35",
        }

        first_server = create_server("127.0.0.1", 0, data_directory, "test-token")
        first_thread = threading.Thread(target=first_server.serve_forever, daemon=True)
        first_thread.start()
        first_url = first_server.service.public_base_url
        try:
            payload = json.dumps({"id": recording_id}).encode()
            status, _, _ = self.request(
                "POST",
                "/v1/recordings",
                payload,
                {"Content-Type": "application/json"},
                base_url=first_url,
            )
            self.assertEqual(status, 201)
            status, body, _ = self.request(
                "PUT",
                f"/v1/recordings/{recording_id}/chunks/1",
                chunk,
                chunk_headers,
                base_url=first_url,
            )
            self.assertEqual(status, 200, body)
        finally:
            first_server.shutdown()
            first_server.server_close()
            first_server.service.database.close()
            first_thread.join(timeout=5)

        second_server = create_server("127.0.0.1", 0, data_directory, "test-token")
        second_thread = threading.Thread(target=second_server.serve_forever, daemon=True)
        second_thread.start()
        second_url = second_server.service.public_base_url
        try:
            status, body, _ = self.request(
                "GET", f"/v1/recordings/{recording_id}", base_url=second_url
            )
            self.assertEqual(status, 200, body)
            persisted = json.loads(body)
            self.assertEqual(persisted["status"], "RECORDING")
            self.assertEqual(persisted["chunk_count"], 1)

            status, body, _ = self.request(
                "PUT",
                f"/v1/recordings/{recording_id}/chunks/1",
                chunk,
                chunk_headers,
                base_url=second_url,
            )
            self.assertEqual(status, 200, body)
            self.assertTrue(json.loads(body)["duplicate"])

            status, body, _ = self.request(
                "POST", f"/v1/recordings/{recording_id}/finish", b"", base_url=second_url
            )
            self.assertEqual(status, 200, body)
            self.assertEqual(json.loads(body)["status"], "COMPLETED")
            status, audio, _ = self.request(
                "GET", f"/v1/recordings/{recording_id}/audio", base_url=second_url
            )
            self.assertEqual(status, 200)
            self.assertIn(b"ftyp", audio[:64])
        finally:
            second_server.shutdown()
            second_server.server_close()
            second_server.service.database.close()
            second_thread.join(timeout=5)

    def test_s3_configuration_is_validated_before_activation_and_mirrors_audio(self) -> None:
        data_directory = self.root / "s3-data"
        factory = FakeS3Factory()
        server = create_server(
            "127.0.0.1",
            0,
            data_directory,
            "test-token",
            s3_client_factory=factory,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base_url = server.service.public_base_url
        try:
            status, body, _ = self.request("GET", "/v1/storage/config", base_url=base_url)
            self.assertEqual(status, 200, body)
            self.assertEqual(json.loads(body), {"mode": "local"})

            invalid = json.dumps(
                {
                    "mode": "s3",
                    "bucket": "unreachable",
                    "region": "us-east-1",
                    "access_key_id": "key",
                    "secret_access_key": "secret",
                }
            ).encode()
            status, body, _ = self.request(
                "PUT",
                "/v1/storage/config",
                invalid,
                {"Content-Type": "application/json"},
                base_url=base_url,
            )
            self.assertEqual(status, 422, body)
            self.assertEqual(json.loads(body)["error"], "storage_configuration_invalid")
            self.assertFalse((data_directory / "storage-config.json").exists())

            valid = json.dumps(
                {
                    "mode": "s3",
                    "bucket": "meetings",
                    "region": "us-east-1",
                    "endpoint_url": "https://s3.example.test",
                    "prefix": "my-recordings",
                    "access_key_id": "key",
                    "secret_access_key": "secret",
                    "force_path_style": True,
                }
            ).encode()
            status, body, _ = self.request(
                "PUT",
                "/v1/storage/config",
                valid,
                {"Content-Type": "application/json"},
                base_url=base_url,
            )
            self.assertEqual(status, 200, body)
            response = json.loads(body)
            self.assertTrue(response["validated"])
            self.assertNotIn("secret_access_key", response)
            self.assertEqual((data_directory / "storage-config.json").stat().st_mode & 0o777, 0o600)

            recording_id = "rec_s3"
            payload = json.dumps({"id": recording_id}).encode()
            self.assertEqual(
                self.request(
                    "POST",
                    "/v1/recordings",
                    payload,
                    {"Content-Type": "application/json"},
                    base_url=base_url,
                )[0],
                201,
            )
            chunk = self.chunks[0]
            status, body, _ = self.request(
                "PUT",
                f"/v1/recordings/{recording_id}/chunks/1",
                chunk,
                {
                    "X-Chunk-Checksum": hashlib.sha256(chunk).hexdigest(),
                    "X-Chunk-Started-At": "2026-08-23T00:00:00.000Z",
                    "X-Chunk-Duration": "0.35",
                },
                base_url=base_url,
            )
            self.assertEqual(status, 200, body)
            status, body, _ = self.request(
                "POST", f"/v1/recordings/{recording_id}/finish", b"", base_url=base_url
            )
            self.assertEqual(status, 200, body)
            self.assertIn(
                ("meetings", f"my-recordings/recordings/{recording_id}/chunks/000001.m4a"),
                factory.objects,
            )
            self.assertIn(
                ("meetings", f"my-recordings/recordings/{recording_id}/source.m4a"),
                factory.objects,
            )
        finally:
            server.shutdown()
            server.server_close()
            server.service.database.close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
