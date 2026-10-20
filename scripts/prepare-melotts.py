#!/usr/bin/env python3
"""Prepare the pinned, official sherpa-onnx MeloTTS Chinese model for an iOS build."""
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
URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-melo-tts-zh_en.tar.bz2"
# Pinned from the verified release archive (2026-10-19 download).
EXPECTED_SHA256 = "e58351ed7149f290a54534538badd4077cdbe6fddc964b24d0bee870415d1514"
TOP = "vits-melo-tts-zh_en"
REQUIRED = ["model.onnx", "lexicon.txt", "tokens.txt", "dict"]


def prepare(archive: Path, destination: Path):
    checksum = hashlib.sha256()
    with archive.open("rb") as incoming:
        for block in iter(lambda: incoming.read(1024 * 1024), b""):
            checksum.update(block)
    digest = checksum.hexdigest()
    if EXPECTED_SHA256 and digest != EXPECTED_SHA256:
        raise ValueError("MeloTTS archive checksum mismatch; refusing to install")
    with tempfile.TemporaryDirectory(prefix="melo-", dir=ROOT / ".build") as temporary:
        stage = Path(temporary)
        total = 0
        with tarfile.open(archive, "r:bz2") as source:
            for member in source:
                name = PurePosixPath(member.name)
                if name.is_absolute() or ".." in name.parts or not name.parts or name.parts[0] != TOP:
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
        model = stage / TOP
        if not all((model / item).exists() for item in REQUIRED):
            raise ValueError("Incomplete MeloTTS model")
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(model, destination, dirs_exist_ok=True)
        # The release package ships model.int8.onnx as a 133-byte git-LFS pointer stub.
        (destination / "model.int8.onnx").unlink(missing_ok=True)
        (destination / ".gitkeep").touch()
        manifest = {"model": "myshell-ai/MeloTTS-Chinese", "runtime_format": "sherpa-onnx vits-melo-tts-zh_en",
                    "source": URL, "sha256": digest, "speakers": 1}
        (destination / "readora-model.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Prepared MeloTTS: {destination}\nsha256={digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    cache = ROOT / ".build/melo-runtime/model.tar.bz2"
    cache.parent.mkdir(parents=True, exist_ok=True)
    archive = args.archive or cache
    if not archive.exists():
        partial = archive.with_suffix(".download")
        print("Downloading official MeloTTS Chinese model…", flush=True)
        urllib.request.urlretrieve(URL, partial)
        os.replace(partial, archive)
    prepare(archive, ROOT / "Resources/iOS/MeloTTS")


if __name__ == "__main__":
    main()
