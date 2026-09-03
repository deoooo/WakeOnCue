from __future__ import annotations

import argparse
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path


SEGMENTATION_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
)
EMBEDDING_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "speaker-recongition-models/"
    "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
)


def download(url: str, destination: Path) -> None:
    if destination.is_file() and destination.stat().st_size > 0:
        print(f"Already present: {destination}")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    print(f"Downloading {url}")
    with urllib.request.urlopen(url) as response, temporary.open("wb") as output:
        shutil.copyfileobj(response, output)
    temporary.replace(destination)


def safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    destination_root = destination.resolve()
    with tarfile.open(archive, "r:bz2") as handle:
        for member in handle.getmembers():
            member_path = (destination / member.name).resolve()
            if destination_root not in member_path.parents and member_path != destination_root:
                raise RuntimeError(f"unsafe model archive member: {member.name}")
        try:
            handle.extractall(destination, filter="data")
        except TypeError:
            handle.extractall(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description="Download public WakeOnCue diarization models")
    parser.add_argument("--output", type=Path, default=Path(".local/models"))
    args = parser.parse_args()
    output = args.output.resolve()
    segmentation_model = (
        output / "sherpa-onnx-pyannote-segmentation-3-0" / "model.onnx"
    )
    embedding_model = (
        output / "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
    )

    if not segmentation_model.is_file():
        with tempfile.TemporaryDirectory() as temporary_directory:
            archive = Path(temporary_directory) / "segmentation.tar.bz2"
            download(SEGMENTATION_URL, archive)
            safe_extract(archive, output)
    download(EMBEDDING_URL, embedding_model)
    if not segmentation_model.is_file():
        raise RuntimeError(f"segmentation model was not extracted to {segmentation_model}")
    print(f"Speaker diarization models ready in {output}")


if __name__ == "__main__":
    main()
