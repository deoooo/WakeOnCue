# sherpa-onnx C API header

`c-api.h` is copied unchanged from [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) v2.0.1
(`sherpa-onnx/c-api/c-api.h`), under the Apache License 2.0 in `LICENSE`.

Only the header is in the repository. The libraries (`sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib`)
and the models are downloaded from the official GitHub releases when the user enables a model,
checked against the SHA-256 published there, and loaded at run time. See
`WakeOnCue/Transcription/ASRModels.swift`.
