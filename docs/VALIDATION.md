# Preview validation

## Native Responses transport correction (0.1.3)

The 358-input source manifest has SHA-256
`6fbbfd6d794a6f8594a03171fcef281e34f2055bdbc24dcf0d9dd42906388e52`.
The full optimized native gate passed 1,196 tests with zero failures in
45.835 seconds (45.919 seconds including suite completion). Regression coverage
checks the exact GET Responses fallback status, refusal of invalid capabilities
and foreign origins, HTTP-only native/provider catalog rows, ordered DeepSeek
presets and the independent High default.

The earlier 0.1.2 metadata checks did not exercise a real Codex turn or remote
compaction. A WebSocket probe could receive HTTP 400 and abort instead of
falling back to HTTP. The corrected route returns 426 after its existing
capability/origin checks, and publishes `prefer_websockets: false`. Direct HTTP
inference alone is insufficient validation of this client behavior.

The final packaged shim also passed three real Codex 0.165.0 client
scenarios using private test configuration and data homes: a native subscription
model, the documented CommandCode DeepSeek model, and a native model with a
forced WebSocket catalog preference. Each completed an actual shell/file-tool
turn, explicit context compaction and a subsequent turn recalling the test
value. The client logs confirm HTTP fallback. Both the client and shim were
denied access to the optional Web bridge port. All owned processes exited
successfully; copied test credentials were removed and the global Codex
configuration remained byte-identical during the proof.

The outer port-denial sandbox used a full-access Codex tool policy to avoid
unsupported nested sandbox application. This is isolated routing/configuration
validation, not a filesystem-confinement, GUI or every-provider certificate.
The first controls retained fixture failures involving a prompt that did not
execute the requested action, nested sandbox application, and submitting a
continuation before compaction's terminal notification. The final proof waits
for that terminal notification and verifies the actual file contents.

The packaged app contains 18 regular files and five macOS 14/SDK 26.5 arm64
executables. All 22 ZIP entries match the staged package, with no CRC failures.
ZIP SHA-256: `dcc3814f104e9952857b17c2c894623ae7b887f36dc7bf65b55dc30977899ffb`.
Signing remains ad-hoc; notarization and Intel/macOS 14 physical runtime
acceptance remain unverified.

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
