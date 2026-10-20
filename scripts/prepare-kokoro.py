#!/usr/bin/env python3
"""Prepare the pinned, official Kokoro Chinese/English model for an iOS build."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_1.tar.bz2"
# Filled from the verified release archive prepared with this integration.
EXPECTED_SHA256 = "a3f4c73d043860e3fd2e5b06f36795eb81de0fc8e8de6df703245edddd87dbad"
REQUIRED = ["model.onnx", "voices.bin", "tokens.txt", "lexicon-zh.txt", "lexicon-us-en.txt", "espeak-ng-data"]


def prepare(archive: Path, destination: Path):
    checksum = hashlib.sha256()
    with archive.open("rb") as incoming:
        for block in iter(lambda: incoming.read(1024 * 1024), b""):
            checksum.update(block)
    digest = checksum.hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError("Kokoro archive checksum mismatch; refusing to install")
    with tempfile.TemporaryDirectory(prefix="kokoro-", dir=ROOT / ".build") as temporary:
        stage = Path(temporary)
        total = 0
        with tarfile.open(archive, "r:bz2") as source:
            for member in source:
                name = PurePosixPath(member.name)
                if name.is_absolute() or ".." in name.parts or not name.parts or name.parts[0] != "kokoro-multi-lang-v1_1":
                    raise ValueError("Unsafe archive member")
                target = stage.joinpath(*name.parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    total += member.size
                    if member.size > 1024**3 or total > 2 * 1024**3:
                        raise ValueError("Model archive exceeds preparation limits")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as incoming, target.open("wb") as outgoing:
                        shutil.copyfileobj(incoming, outgoing)
                else:
                    raise ValueError("Links and special files are not accepted")
        model = stage / "kokoro-multi-lang-v1_1"
        if not all((model / item).exists() for item in REQUIRED):
            raise ValueError("Incomplete Kokoro model")
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(model, destination, dirs_exist_ok=True)
        (destination / ".gitkeep").touch()
        manifest = {"model": "hexgrad/Kokoro-82M-v1.1-zh", "runtime_format": "sherpa-onnx kokoro-multi-lang-v1_1", "source": URL, "sha256": digest}
        (destination / "readora-model.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Prepared Kokoro: {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    cache = ROOT / ".build/kokoro-runtime/model.tar.bz2"
    cache.parent.mkdir(parents=True, exist_ok=True)
    archive = args.archive or cache
    if not archive.exists():
        partial = archive.with_suffix(".download")
        print("Downloading official Kokoro Chinese model…", flush=True)
        urllib.request.urlretrieve(URL, partial)
        os.replace(partial, archive)
    prepare(archive, ROOT / "Resources/iOS/Kokoro")


if __name__ == "__main__":
    main()
