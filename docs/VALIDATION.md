# Preview validation

## Onboarding presentation refinement (0.1.5 candidate)

Only `NativeOnboardingView.swift` changes application behavior. The admission
policy, preference keys, completion callbacks and destination handoff are
unchanged. A focused optimized link compiled nine actual UI sources with 159
retained Core, Presentation and C objects using macOS 14/SDK 26.5. The isolated
native preview produced 340 frames over 17 seconds and 24 static captures: four
steps in Light/Dark at 820×660, 760×580 and 700×580 points. Static captures use
reduced motion. The source and representative images received independent
review; small-window findings were corrected before the final captures.

The production view hash is
`f76ee3406fff5ca94e3dbead95dcc16630d48b884b3e461ee2a77bc269ff1f41`.
The recording scripts step and appearance changes in a private copy, using
sample preferences and an invisible, unordered native host outside all displays.
No app session, services or physical input are used. The video is a walkthrough,
not compositor frame-rate, keyboard, VoiceOver or full-shell acceptance. At
700×580 the optional Whisper note requires scrolling; normal app windows have
a 900×600 minimum and Settings replays setup at 820×660.

The public source-boundary and credential checks passed for the final tree.
All 57 unchanged Python fixtures passed in the preceding presentation iteration;
CI separately checks the submitted revision. Core and tests are unchanged; the
prior 1,251 native test result below is not a new execution for this change.

The full production app compiled in 137.53 seconds. The reviewed 0.1.5 package
contains 18 app files totaling 29,866,377 logical bytes and five executables,
all with macOS 14 minimum/SDK 26.5 headers. Strict ad-hoc signature checks passed.
All 22 ZIP entries match staging byte for byte, with no CRC failures. The ZIP is
12,574,785 bytes, SHA-256:
`29253dd9c6785ab8d11d4494655d7d1c8730d823a2e45874f9796b15d54879cb`.
This is build and artifact evidence, separate from installation, native input
and notarization.

## Onboarding, Settings and streaming (0.1.4 candidate)

The gate's 372-input native source manifest has SHA-256
`2db4552c9222e28a272127ca2fc1f0a1b6c0a2b59498c7fabbeb88dd65c672c9`.
The optimized gate passed **1,251 tests, zero failures**, in 48.820 seconds
(48.920 seconds including suite completion). All UI and three Swift products
compiled in 152.53 seconds; the complete command exited successfully after
204.496 seconds. The 57 isolated Python fixtures also passed.

New coverage includes first-run admission and interrupted setup, launch-page
precedence and anchored destinations, theme parsing/presets/undo/contrast,
explicit Telegram chat discovery and redacted failures, provider HTTP 401,
actual response send-loop completion and cancellation, and exact stream-clock
identity/counter matching. Persistence fixtures cover new responses arriving
while Statistics is closed, journal rotation before transcript import, database
read/save failure retries, and consistent bounded warm/cold retention.
Translated Responses retain an upstream's explicitly reported reasoning count;
missing counters remain unknown. Synthetic transcript fixtures establish the
join contract; they do not establish every actual client/provider combination.

Four UI-only files were polished after that gate: the read-only Settings
status row, theme variant label, Statistics cost tile and price disclosure.
The final 372-input source manifest is
`eea33c5f295ff370565af9d063f2b0ddf8e9762d69c3ab167fdb03e36138a688`.
Core and tests are unchanged. The final production package compiles these UI
sources; their layout was recaptured separately.

Twenty-two final native bitmaps cover complete empty Statistics, Transcribe
and Settings pages plus expanded sidebar, Telegram and common/advanced theme
sections in Light/Dark at wide and narrow widths. The Settings detail copies
only initialize disclosure state and add transparent scroll anchors. Eighteen
additional captures cover the complete empty Statistics page and synthetic
empty, unknown, partial and fully priced cost-summary components in both
appearances at 420/720-point widths. Components do not prove full-page layout.
Each capture records an invisible, unordered panel outside all displays without
app activation or global input. Selected images and scope labels are published
in the screenshot manifest. No operator data or hardware is used.

A separate isolated Settings app compiled, but the native UI tool could not
discover its offscreen application. No interaction success is inferred; the
owned fixture processes were stopped. Earlier capture-tool build errors were
also preserved and excluded. Native bitmaps do not establish button/drag input,
animation frame rates, compositor behavior or fresh-user installation.

The final arm64 production package contains 18 app files and five executables,
all targeting macOS 14/SDK 26.5. All 22 ZIP entries match staging byte for byte,
with no CRC failures. The app occupies 29,766,697 logical bytes; the ZIP is
12,536,146 bytes. ZIP SHA-256:
`70634bc61bdb3c3f0ebe6dc474a6ed3ccdf60d291f213f14b126d594386dbc84`.
Strict ad-hoc signature verification passed. Signing is not notarized and does
not establish a verified publisher. Existing-user installation remains separate
from source, fixture and artifact validation; guarded updates can refuse active
calls or an active presentation.

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
