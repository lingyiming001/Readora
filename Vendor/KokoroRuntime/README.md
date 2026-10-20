# Readora Kokoro runtime

A narrow Swift actor around the official sherpa-onnx C API, with only the iOS binary dependencies required by Readora. Model construction and synthesis run serially off the UI actor. Generated audio is copied before native memory is released.

Binary releases and SHA-256 values are pinned to the upstream Swift packages:

- https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/Package.swift
- https://github.com/csukuangfj/onnxruntime-libs/blob/1.28.2/Package.swift
- https://k2-fsa.github.io/sherpa/onnx/tts/all/Chinese-English/kokoro-multi-lang-v1_1.html

Run `python3 scripts/prepare-kokoro.py` from the project root before building the iOS application. Weights are generated resources and are not committed. The model folder and its upstream notices are copied unchanged into the application. This package is linked only by the iOS application; the existing macOS/Swift Package targets are unchanged.
