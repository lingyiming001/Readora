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


SPEAKER_IDS = [0, 1, 2, 3, 11, 23, 33, 43, 56, 58, 60, 68, 78, 88, 102]

def compact_model(source: Path, destination: Path):
    # CPU inference stays FP32. ORT folds these constant casts during session
    # optimization, avoiding unsupported CPU FP16 operators and slow INT8 kernels.
    try:
        import numpy as np
        import onnx
        from onnx import TensorProto, helper, numpy_helper
    except ImportError as error:
        raise RuntimeError("Install preparation dependencies: pip install onnx==1.20.1 numpy==2.5.4") from error
    destination.mkdir(parents=True, exist_ok=True)
    graph = onnx.load(source / "model.onnx")
    names = {value.name for value in graph.graph.initializer}
    casts = []
    for value in graph.graph.initializer:
        if value.data_type != TensorProto.FLOAT:
            continue
        original = value.name
        stored = original + "__readora_fp16"
        if stored in names:
            raise ValueError("Unexpected model initializer collision")
        array = numpy_helper.to_array(value).astype(np.float16)
        if not np.isfinite(array).all():
            raise ValueError("Model weight is outside FP16 range")
        value.CopyFrom(numpy_helper.from_array(array, stored))
        casts.append(helper.make_node("Cast", [stored], [original], name=stored + "_cast", to=TensorProto.FLOAT))
    nodes = list(graph.graph.node)
    del graph.graph.node[:]
    graph.graph.node.extend(casts + nodes)
    meta = {value.key: value for value in graph.metadata_props}
    original_count = int(meta["n_speakers"].value)
    speakers = [meta["speaker_names"].value.split(",")[i] for i in SPEAKER_IDS]
    meta["n_speakers"].value = str(len(speakers))
    meta["speaker_names"].value = ",".join(speakers)
    meta["id2speaker"].value = ",".join(f"{i}->{name}" for i, name in enumerate(speakers))
    meta["speaker2id"].value = ",".join(f"{name}->{i}" for i, name in enumerate(speakers))
    onnx.checker.check_model(graph)
    onnx.save(graph, destination / "model.onnx")
    voices = (source / "voices.bin").read_bytes()
    if len(voices) % original_count:
        raise ValueError("Unexpected speaker table size")
    row = len(voices) // original_count
    (destination / "voices.bin").write_bytes(b"".join(voices[i * row:(i + 1) * row] for i in SPEAKER_IDS))
    for name in ["tokens.txt", "lexicon-zh.txt", "lexicon-us-en.txt", "date-zh.fst", "number-zh.fst", "phone-zh.fst", "LICENSE"]:
        if (source / name).exists():
            shutil.copy2(source / name, destination / name)
    shutil.copytree(source / "espeak-ng-data", destination / "espeak-ng-data")


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
        compact = stage / "compact"
        compact_model(model, compact)
        manifest = {"model": "hexgrad/Kokoro-82M-v1.1-zh", "runtime_format": "sherpa-onnx kokoro-multi-lang-v1_1", "source": URL, "sha256": digest,
                    "speaker_ids": SPEAKER_IDS, "quantization": "FP16 weight storage, FP32 CPU computation (constant-folded Cast)",
                    "model_sha256": hashlib.sha256((compact / "model.onnx").read_bytes()).hexdigest()}
        (compact / "readora-model.json").write_text(json.dumps(manifest, indent=2) + "\n")
        destination.parent.mkdir(parents=True, exist_ok=True)
        backup = None
        if destination.exists():
            backup = Path(tempfile.mkdtemp(prefix="kokoro-previous-", dir=ROOT / ".build")) / "Kokoro"
            destination.rename(backup)
        try:
            shutil.move(str(compact), str(destination))
        except Exception:
            if backup is not None and not destination.exists():
                backup.rename(destination)
            raise
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
