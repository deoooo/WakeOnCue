from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import threading
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, BinaryIO, Callable


class ChecksumMismatch(ValueError):
    pass


class MergeError(RuntimeError):
    pass


class StorageConfigurationError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class S3Configuration:
    bucket: str
    region: str
    access_key_id: str
    secret_access_key: str
    endpoint_url: str | None = None
    prefix: str = "wakeoncue"
    session_token: str | None = None
    force_path_style: bool = False

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> "S3Configuration":
        def required(name: str) -> str:
            value = payload.get(name)
            if not isinstance(value, str) or not value.strip():
                raise StorageConfigurationError(f"{name} is required")
            return value.strip()

        endpoint = payload.get("endpoint_url")
        if endpoint is not None and (not isinstance(endpoint, str) or not endpoint.strip()):
            endpoint = None
        if endpoint and not endpoint.startswith(("http://", "https://")):
            raise StorageConfigurationError("endpoint_url must use http or https")
        prefix = payload.get("prefix", "wakeoncue")
        if not isinstance(prefix, str):
            raise StorageConfigurationError("prefix must be a string")
        token = payload.get("session_token")
        if token is not None and not isinstance(token, str):
            raise StorageConfigurationError("session_token must be a string")
        return cls(
            bucket=required("bucket"),
            region=required("region"),
            access_key_id=required("access_key_id"),
            secret_access_key=required("secret_access_key"),
            endpoint_url=endpoint.strip() if endpoint else None,
            prefix=prefix.strip().strip("/"),
            session_token=token.strip() if token else None,
            force_path_style=bool(payload.get("force_path_style", False)),
        )

    def public_dict(self) -> dict[str, Any]:
        return {
            "mode": "s3",
            "bucket": self.bucket,
            "region": self.region,
            "endpoint_url": self.endpoint_url,
            "prefix": self.prefix,
            "force_path_style": self.force_path_style,
            "has_credentials": True,
        }


class StorageConfigurationManager:
    """Atomically persists and activates the single-user storage destination."""

    def __init__(
        self,
        path: Path,
        client_factory: Callable[[S3Configuration], Any] | None = None,
    ) -> None:
        self.path = path
        self._client_factory = client_factory or self._default_client
        self._lock = threading.RLock()
        self._configuration: S3Configuration | None = None
        self._client: Any | None = None
        self._load()

    def public_configuration(self) -> dict[str, Any]:
        with self._lock:
            return self._configuration.public_dict() if self._configuration else {"mode": "local"}

    def current(self) -> tuple[S3Configuration, Any] | None:
        with self._lock:
            if self._configuration is None:
                return None
            if self._client is None:
                self._client = self._client_factory(self._configuration)
            return self._configuration, self._client

    def update(self, payload: dict[str, Any]) -> dict[str, Any]:
        mode = payload.get("mode")
        if mode == "local":
            with self._lock:
                self.path.unlink(missing_ok=True)
                self._configuration = None
                self._client = None
            return {"mode": "local", "validated": True}
        if mode != "s3":
            raise StorageConfigurationError("mode must be local or s3")
        with self._lock:
            existing = self._configuration
        resolved_payload = dict(payload)
        if existing is not None:
            if not resolved_payload.get("access_key_id"):
                resolved_payload["access_key_id"] = existing.access_key_id
            if not resolved_payload.get("secret_access_key"):
                resolved_payload["secret_access_key"] = existing.secret_access_key
            if "session_token" not in resolved_payload:
                resolved_payload["session_token"] = existing.session_token
        configuration = S3Configuration.from_payload(resolved_payload)
        client = self._client_factory(configuration)
        probe_key = self.key(configuration, f".connection-test/{uuid.uuid4().hex}")
        body = b"wakeoncue-storage-check"
        try:
            client.put_object(
                Bucket=configuration.bucket,
                Key=probe_key,
                Body=body,
                ContentType="application/octet-stream",
                Metadata={"wakeoncue-probe": "true"},
            )
            response = client.head_object(Bucket=configuration.bucket, Key=probe_key)
            if int(response.get("ContentLength", -1)) != len(body):
                raise StorageConfigurationError("S3 verification returned an unexpected object size")
            client.delete_object(Bucket=configuration.bucket, Key=probe_key)
        except StorageConfigurationError:
            raise
        except Exception as error:
            try:
                client.delete_object(Bucket=configuration.bucket, Key=probe_key)
            except Exception:
                pass
            raise StorageConfigurationError(f"S3 connection check failed: {error}") from error
        self._persist(configuration)
        with self._lock:
            self._configuration = configuration
            self._client = client
        return {**configuration.public_dict(), "validated": True}

    @staticmethod
    def key(configuration: S3Configuration, suffix: str) -> str:
        return "/".join(part for part in (configuration.prefix, suffix.lstrip("/")) if part)

    def _load(self) -> None:
        if not self.path.is_file():
            return
        payload = json.loads(self.path.read_text(encoding="utf-8"))
        self._configuration = S3Configuration.from_payload(payload)

    def _persist(self, configuration: S3Configuration) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(f".{self.path.name}.{uuid.uuid4().hex}.tmp")
        try:
            temporary.write_text(
                json.dumps({"mode": "s3", **asdict(configuration)}, sort_keys=True),
                encoding="utf-8",
            )
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.path)
        finally:
            temporary.unlink(missing_ok=True)

    @staticmethod
    def _default_client(configuration: S3Configuration) -> Any:
        import boto3
        from botocore.config import Config

        client_options: dict[str, Any] = {
            "region_name": configuration.region,
            "endpoint_url": configuration.endpoint_url,
            "aws_access_key_id": configuration.access_key_id,
            "aws_secret_access_key": configuration.secret_access_key,
            "aws_session_token": configuration.session_token,
        }
        client_options["config"] = Config(
            connect_timeout=5,
            read_timeout=10,
            retries={"max_attempts": 2, "mode": "standard"},
            s3={"addressing_style": "path" if configuration.force_path_style else "auto"},
        )
        return boto3.client("s3", **client_options)


class LocalRecordingStorage:
    """Filesystem implementation behind the replaceable storage boundary."""

    def __init__(self, root: Path, ffmpeg_binary: str = "ffmpeg") -> None:
        self.root = root
        self.ffmpeg_binary = ffmpeg_binary
        self.root.mkdir(parents=True, exist_ok=True)

    def recording_directory(self, recording_id: str) -> Path:
        return self.root / "recordings" / recording_id

    def write_chunk(
        self,
        recording_id: str,
        chunk_index: int,
        source: BinaryIO,
        expected_checksum: str,
        content_length: int,
    ) -> tuple[Path, int]:
        directory = self.recording_directory(recording_id) / "chunks"
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / f"{chunk_index:06d}.m4a"
        temporary = directory / f".{chunk_index:06d}.{uuid.uuid4().hex}.upload"
        digest = hashlib.sha256()
        written = 0
        try:
            with temporary.open("wb") as handle:
                remaining = content_length
                while remaining:
                    block = source.read(min(1024 * 1024, remaining))
                    if not block:
                        raise IOError("request body ended before Content-Length")
                    handle.write(block)
                    digest.update(block)
                    written += len(block)
                    remaining -= len(block)
                handle.flush()
                os.fsync(handle.fileno())
            actual_checksum = digest.hexdigest()
            if actual_checksum != expected_checksum:
                raise ChecksumMismatch(
                    f"checksum mismatch: expected {expected_checksum}, got {actual_checksum}"
                )
            os.replace(temporary, target)
            directory_fd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            return target, written
        finally:
            temporary.unlink(missing_ok=True)

    def merge_chunks(self, recording_id: str, chunks: list[dict[str, object]]) -> Path:
        directory = self.recording_directory(recording_id)
        merged_directory = directory / "merged"
        merged_directory.mkdir(parents=True, exist_ok=True)
        concat_file = merged_directory / "chunks.txt"
        output = merged_directory / "source.m4a"
        temporary_output = merged_directory / f".{uuid.uuid4().hex}.source.m4a"
        concat_file.write_text(
            "".join(f"file '{self._escape_concat_path(Path(str(chunk['path'])))}'\n" for chunk in chunks),
            encoding="utf-8",
        )
        try:
            process = subprocess.run(
                [
                    self.ffmpeg_binary,
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-f",
                    "concat",
                    "-safe",
                    "0",
                    "-i",
                    str(concat_file),
                    "-c",
                    "copy",
                    "-movflags",
                    "+faststart",
                    "-y",
                    str(temporary_output),
                ],
                capture_output=True,
                text=True,
                timeout=120,
                check=False,
            )
            if process.returncode != 0:
                raise MergeError(process.stderr.strip() or "ffmpeg failed")
            os.replace(temporary_output, output)
            return output
        except FileNotFoundError as error:
            raise MergeError(f"ffmpeg not found: {self.ffmpeg_binary}") from error
        finally:
            temporary_output.unlink(missing_ok=True)
            concat_file.unlink(missing_ok=True)

    def open_audio(self, recording_id: str) -> tuple[Path, int]:
        path = self.recording_directory(recording_id) / "merged" / "source.m4a"
        if not path.is_file():
            raise FileNotFoundError(path)
        return path, path.stat().st_size

    @staticmethod
    def sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while block := handle.read(1024 * 1024):
                digest.update(block)
        return digest.hexdigest()

    @staticmethod
    def _escape_concat_path(path: Path) -> str:
        return str(path.resolve()).replace("'", "'\\''")


class ConfigurableRecordingStorage:
    """Local source-of-truth with an optional S3 durable mirror."""

    def __init__(
        self,
        local: LocalRecordingStorage,
        configuration_manager: StorageConfigurationManager,
    ) -> None:
        self.local = local
        self.configuration_manager = configuration_manager

    def write_chunk(
        self,
        recording_id: str,
        chunk_index: int,
        source: BinaryIO,
        expected_checksum: str,
        content_length: int,
    ) -> tuple[Path, int]:
        path, size = self.local.write_chunk(
            recording_id, chunk_index, source, expected_checksum, content_length
        )
        active = self.configuration_manager.current()
        if active:
            configuration, client = active
            key = self._chunk_key(configuration, recording_id, chunk_index)
            client.upload_file(
                str(path), configuration.bucket, key,
                ExtraArgs={"ContentType": "audio/mp4", "Metadata": {"sha256": expected_checksum}},
            )
        return path, size

    def is_chunk_durable(
        self,
        recording_id: str,
        chunk_index: int,
        path: Path,
        checksum: str,
        size: int,
    ) -> bool:
        if not path.is_file() or path.stat().st_size != size or self.sha256(path) != checksum:
            return False
        active = self.configuration_manager.current()
        if not active:
            return True
        configuration, client = active
        try:
            response = client.head_object(
                Bucket=configuration.bucket,
                Key=self._chunk_key(configuration, recording_id, chunk_index),
            )
            metadata = response.get("Metadata", {})
            return int(response.get("ContentLength", -1)) == size and metadata.get("sha256") == checksum
        except Exception:
            return False

    def merge_chunks(self, recording_id: str, chunks: list[dict[str, object]]) -> Path:
        output = self.local.merge_chunks(recording_id, chunks)
        active = self.configuration_manager.current()
        if active:
            configuration, client = active
            try:
                client.upload_file(
                    str(output),
                    configuration.bucket,
                    self._audio_key(configuration, recording_id),
                    ExtraArgs={"ContentType": "audio/mp4"},
                )
            except Exception as error:
                raise MergeError(f"S3 upload failed: {error}") from error
        return output

    def open_audio(self, recording_id: str) -> tuple[Path, int]:
        try:
            return self.local.open_audio(recording_id)
        except FileNotFoundError:
            active = self.configuration_manager.current()
            if not active:
                raise
            configuration, client = active
            target = self.local.recording_directory(recording_id) / "merged" / "source.m4a"
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(f".{uuid.uuid4().hex}.download")
            try:
                client.download_file(
                    configuration.bucket,
                    self._audio_key(configuration, recording_id),
                    str(temporary),
                )
                os.replace(temporary, target)
            finally:
                temporary.unlink(missing_ok=True)
            return target, target.stat().st_size

    def sha256(self, path: Path) -> str:
        return self.local.sha256(path)

    def _chunk_key(self, configuration: S3Configuration, recording_id: str, index: int) -> str:
        return self.configuration_manager.key(
            configuration, f"recordings/{recording_id}/chunks/{index:06d}.m4a"
        )

    def _audio_key(self, configuration: S3Configuration, recording_id: str) -> str:
        return self.configuration_manager.key(
            configuration, f"recordings/{recording_id}/source.m4a"
        )
