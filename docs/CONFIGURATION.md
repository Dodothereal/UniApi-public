# Configuration

## Providers

UniApi ships with an empty `providers.example.json`. Bring your own provider endpoints, model identifiers and credentials. No paid subscription, free quota or vendor account is included.

Use the app's provider controls to configure an integration. Provider format, model discovery and tool support vary; a discovered model is not evidence that coding tools work with it. Test the action you intend to use before relying on a route. Provider requests can incur charges under your account's terms.

Provider keys are stored locally in `providers.json` as plaintext by design. Protect this file and backups with owner-only access; never commit or attach them to an issue. Vendor login, where supported, is optional. Browser credentials must remain in their dedicated credential store rather than being copied into provider-key fields.

## Data locations

The native runtime resolves these overrides at startup:

| Variable | Meaning |
| --- | --- |
| `UNIAPI_ROOT` | Root for managed configuration and data |
| `UNIAPI_DATA` | Override for the managed data directory |
| `UNIAPI_PROVIDERS` | Override for the provider JSON file |

Without overrides, the runtime uses a `UniApi` directory in the current user's home, with `data/` and `providers.json` beneath it. The data directory includes `uniapi.sqlite`, logs, temporary files and benchmark state. An installer may preserve an existing installation's configured locations; do not assume changing a terminal variable changes an already running service.

Back up configuration and data together. Keep each running installation's ownership explicit; never point a second running instance at the same writable data. Treat transcripts, job parameters, logs and usage history as private.

## Coding tools and Codex

Coding integrations are optional and depend on the relevant locally installed tool. UniApi does not supply a vendor subscription or sign you in automatically.

Native Codex routing is optional. Use the app's journal-aware handoff to connect or disconnect managed routes so unrelated configuration and another writer's ownership are preserved. Do not manually overwrite shared routing files or assume desktop routing also configures every other coding tool. Authentication, discovery, text inference and full tool execution are separate capabilities.

### Native routing from the command line

The native executable also accepts these commands before UI readiness, AppKit startup or app-session creation:

```sh
uniapi_cli="native/swift/build.noindex/UniApi Native.app/Contents/MacOS/UniApiNative"
"$uniapi_cli" --codex-routing status
"$uniapi_cli" --codex-routing connect
"$uniapi_cli" --codex-routing restore
"$uniapi_cli" --codex-routing connect --wait-for-idle 600
```

Use the staged executable after building, or substitute the installed/extracted app's `Contents/MacOS/UniApiNative`. These commands use the normal runtime's Codex actor without starting services, recovering jobs, creating the app session or starting hardware monitoring. They honor the data overrides above, `CODEX_HOME` and `CODEX_CHATGPT_WEB_HOME`. Status opens the existing runtime storage read-only and does not initialize an absent installation.

`connect` delegates to the same guarded native handoff as the app: it drains the Swift shim, then the integrated Web bridge, uses the bridge's journal-aware route disconnect, and transfers catalog membership through the existing ownership checks. `restore` uses the normal guarded restore action. Neither command stops Web services, cancels active turns, sends inference, edits configuration directly or weakens admission checks. Once connected, API and subscription routing are independent of the optional Web bridge.

The native route uses HTTP Responses for both normal turns and compaction. It
publishes `prefer_websockets: false` and answers a valid-capability
`GET /responses` probe with HTTP 426, so clients with stale WebSocket
preferences can retry with POST instead of aborting the turn. The probe does
not submit an upstream request; invalid capabilities and cross-origin probes
remain refused. A manually stopped or unloaded native shim cannot serve routed
models: restore the route through its guarded journal before removing its owner.
Normal UniApi Quit keeps that background owner running.

Without a wait option, busy required owners cause immediate refusal. Only `connect` accepts `--wait-for-idle SECONDS`, an explicit integer from 1 through 600. It observes healthy required owners once per second, holding no drain while waiting. Before waiting it pins the exact bytes and presence of Codex `config.toml`, `providers.json`, bridge `config.json`, bridge `uniapi-catalog.json` and the destination native catalog. Each poll rechecks those fingerprints, including the last idle observation before invoking the normal action. A changed file, unreadable fingerprint, unhealthy or unknown required owner, unexpected error, cancellation or deadline ends the command without retrying the mutation. Codex's naturally refreshed `models_cache.json` is excluded. An already connected native route never waits: it runs the normal action when idle or immediately reports busy. A disconnected optional Web installation is not a required owner. The guarded action still checks admission again, so traffic arriving after an idle poll can cause refusal.

The wait deadline bounds polling; an in-flight status read or guarded action must finish its existing transport timeout or recovery. SIGINT and SIGTERM cancel the wait with exit 130. Cancellation before the action leaves routing untouched; after an action starts, allow its owned recovery to finish and inspect status before retrying. Do not force-kill a handoff or automatically replay a failed mutation.

Every command prints one JSON result with `command`, `outcome`, `reloadRequired` and a safe status projection. The projection contains only booleans, counts or null: native connection/admission/activity, Web integration/running/busy state, restore availability and error-presence flags. Private paths, base URLs, routing capabilities, credentials, raw manager errors and model/provider identifiers are omitted. Usage errors print a fixed usage result. Exit codes are 0 for status/completion, 2 for busy/unhealthy/changed-intent/timeout refusal, 64 for invalid arguments, 130 for cancellation and 1 for an unexpected error or uncertain postcondition. An acknowledged action is completed only when its returned status explicitly reports clean configuration, native ownership and catalog error fields, a disconnected Web route, and the requested native connection state (connected for `connect`, disconnected for `restore`). A conflicting or missing postcondition returns `outcome: "uncertain"` with exit 1 and no automatic retry. On refusal or error, inspect the app's private diagnostics; a failed action may have committed routing before a later acknowledgement or resume failure. Reload Codex when idle if a completed result sets `reloadRequired`.

Statistics reads supported coding tools' local stores. It does not require configuring every supported tool. Imported history may include private project names and paths; redact it before sharing screenshots or diagnostics.

## Local Transcribe

Local transcription uses the bundled, statically built upstream Whisper v1.9.4 CLI. Real local CLI validation has covered model installation, file transcription, concurrent-use refusal, cancellation, model removal and child-process cleanup. The final 0.1.0 packaged executable passed these checks, including refusal of removal by another process while recognition holds the model lease; this does not establish all app job flows or optional integrations as tested. No Wispr login, vendor account or cloud transcription credentials are needed.

1. Open Transcribe and choose **Install model**. The optional download is 574,041,195 bytes (about 574 MB); opening the page does not download it.
2. After installation, choose a local audio file or a link and start a transcription job. WAV, MP3 and M4A use the native decoder. Other media may need ffmpeg, and links require yt-dlp; see [optional tool setup](INSTALL.md#optional-transcription-tools).
3. Choose **Remove model** when you no longer need the weights. Removal is disabled while the model is in use. You can explicitly install it again later.

The model is `large-v3-turbo` Q5 (`ggml-large-v3-turbo-q5_0.bin`), stored beneath the managed data directory in `local-models/whisper/`. Installation verifies the pinned byte count and SHA-256. The bundled CLI and optional weights are separate assets: building the app does not install the weights, and the release package does not include them.

Each transcription job launches one owned Whisper child process for its pending audio chunks. That process loads one model and releases model memory on exit; UniApi does not keep an always-on Whisper process. Installed weights stay on disk until removed.

### Command line without a window

The bundled `UniApiNative` executable accepts these commands before creating the app session. They do not open a window or start hardware/background services. For a source build, point to the staged executable from the repository root. For a downloaded archive, use the extracted `UniApi.app/Contents/MacOS/UniApiNative` instead:

```sh
uniapi_cli="native/swift/build.noindex/UniApi Native.app/Contents/MacOS/UniApiNative"
"$uniapi_cli" --local-model status
```

Status inspects the model store without downloading weights or creating model storage. Installation requires an explicit command and downloads the same optional 574 MB model used by the UI:

```sh
"$uniapi_cli" --local-model install
"$uniapi_cli" --transcribe-file /absolute/audio.wav
"$uniapi_cli" --transcribe-file /absolute/audio.wav --language en
```

Replace `/absolute/audio.wav` with an absolute path to your file. Omit `--language` for automatic language selection. File transcription requires an already installed model; it does not install one implicitly. The CLI uses the same model store and owned Whisper child as UI transcription, with model memory released on child exit. Its file command uses the native decoder directly; ffmpeg fallback and link retrieval belong to the app's job flow.

Model commands print JSON status; transcription prints text to standard output and progress to standard error. To explicitly remove the installed weights when they are not in use:

```sh
"$uniapi_cli" --local-model remove
```

The commands honor the data-location overrides above. Local CLI checks have confirmed successful transcription and model lifecycle behavior, including cancellation with exit status 130 and successful removal with exit status 0. Completed checks left no Whisper child running and removed the test model weights. These checks passed against the final 0.1.0 packaged executable on macOS 27.2/arm64. No model download occurs on implicit startup.

### Provenance

- Runtime: [official ggml-org/whisper.cpp v1.9.4](https://github.com/ggml-org/whisper.cpp/tree/v1.9.4), built from the checksum-pinned archive by `tools/build-local-whisper.sh`.
- Model: [ggerganov/whisper.cpp model repository](https://huggingface.co/ggerganov/whisper.cpp), using this [revision-pinned Q5 model download](https://huggingface.co/ggerganov/whisper.cpp/resolve/87cd18b47b941d2f65d09981dad23bb7d0481c77/ggml-large-v3-turbo-q5_0.bin). The exact descriptor and checksum live in `native/swift/Sources/UniApiCore/LocalWhisperModels.swift`.
- Runtime license: [bundled Whisper notice](../native/swift/Resources/Whisper-LICENSE.txt). Review the model repository's terms separately from UniApi's MIT license.

Per-transcript notifications default to off. Optional Telegram delivery also requires explicit saved configuration in Settings.

The model download and link retrieval use the network. Transcription of a local file uses the local runtime after model installation. If you choose a provider for summarization, the text sent for that summary leaves the machine.

## Mac controls and background tasks

Fan and battery controls depend on hardware support and may need an explicitly installed helper. Install or change controls only through their supported flow. Preserve your chosen hardware settings during updates and inspect any unsupported-device message before proceeding.

Normal Quit hides the presentation and preserves background work. See [Installation](INSTALL.md#background-work-and-updates) for ownership and update constraints.
