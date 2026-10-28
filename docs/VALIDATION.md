# Preview validation

## Catalog compatibility correction (0.1.2)

The corrected 358-input source manifest has SHA-256
`a05f49ffe75b188f47fce6d0834b62b7e33192c3ec58b45d5c56f86f79f093ef`.
Its full optimized native gate passed 1,192 tests with zero failures in
47.546 seconds (47.632 seconds including suite completion); full UI and three
Swift products compiled in 159.73 seconds.

A real Codex 0.165.0 client rejected the prior generated catalog. Per-process
catalog controls kept global routing unchanged: adding reasoning-preset
descriptions alone restored the model list and DeepSeek High/Low/Max, default
High. Adding only the separately suspected availability field did not fix it.
These metadata checks submitted no inference turns. The production correction
changes only preset descriptions; final installed HTTP-catalog and inference
checks remain separate from these controls.

## Routing CLI validation (0.1.1)

The routing command and catalog-refresh update passed the full optimized native
suite on macOS 27.2/arm64: 1,191 tests, zero failures, in 43.019 seconds
(43.104 seconds including suite completion). The full UI and three Swift
products compiled in 153.43 seconds. The 358-input native source manifest has
SHA-256 `a0894c65c94f8b551462e85afeb3818c7a8bb45b3ff8ee7871ba45bccfa3fa78`.
This includes the new command policy, uncertain-postcondition and stale
None-only catalog regressions. Independent source review covered the guarded
delegation and safe output; no direct configuration writer or forced drain was
introduced. These checks do not themselves establish an installed handoff or
live provider reasoning behavior.

## Published 0.1.0 preview

Version 0.1.0 was validated on Apple Silicon (arm64), running macOS 27.2, with the macOS 26.5 SDK and a macOS 14 deployment target. This is not physical Intel or macOS 14 runtime verification.

| Check | Result |
| --- | --- |
| Optimized Core/Presentation suite | 1,176 tests, zero failures |
| Local transcription/settings subset | 50 tests, zero failures; included in the native total |
| Python packaging, installer and pricing fixtures | 57 tests, zero failures; isolated fixtures, not a real installation |
| Public source boundary and credential scan | Passed |
| Production app signature verification | Passed with ad-hoc signing; no Developer ID or notarization |
| Executable headers | All five executables: arm64, macOS 14 minimum, SDK 26.5 |
| ZIP integrity | All 22 regular entries match the staged package byte for byte; CRC check passed |
| Package size | 12,111,594 bytes compressed; app 28,715,273 logical bytes |

ZIP SHA-256: `0542561f9d85d82399aea9798bc2adf2614b1a868831430e6730b69a710e8dac`.

The actual packaged app downloaded the pinned 574,041,195-byte Whisper model into a new test workspace and verified its SHA-256. It transcribed the upstream whisper.cpp `samples/jfk.wav` clip through the native decoder and bundled local runtime. This is a correctness smoke, not a performance benchmark or a guarantee of transcription accuracy.

A second real process was refused when it tried to remove a model held by an active recognizer. Cancelling the owning CLI returned cancellation status, drained its owned child, and released the lease. Removal then succeeded; no test model weights were left installed. Tests do not use personal audio or another app's speech-service credentials.

The optional model is absent until explicitly installed. Model files are validated by pinned size and SHA-256, private file permissions and ownership. A process-local metadata cache avoids rehashing an unchanged model on every page reload; install/removal and inference coordinate using nonblocking file locks.

## Limits

- No claim of testing every Mac, every provider, every model, every privileged helper or every system dialog.
- No Intel/universal binary or physical Intel runtime acceptance in this preview.
- No Apple notarization or Developer ID signature.
- No always-on transcription daemon; the model runs in an owned child for a job. Runtime and first-load compilation time depend on the Mac.
- Provider/API costs are estimates from the pricing catalog. Unpriced usage remains unknown, not zero. Provider invoices and subscription charges are separate.
- Native page illustrations are distinct from compositor captures, full-shell interaction, hardware acceptance and a fresh installed-user test.

The final UI-only icon, notification-default and slider changes were rebuilt into the package and recaptured separately. Core and Presentation sources are unchanged from the 1,176-test run.
