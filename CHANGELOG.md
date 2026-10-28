# Changelog

User-facing changes are recorded here. Release entries should describe shipped behavior and actual validation, with unresolved limitations kept explicit.

## Unreleased

- Reworked onboarding with a compact step rail, visual appearance previews, aligned controls and a final settings summary. Smaller windows retain accessible navigation and simplify decoration. Setup keeps the same preference, completion and navigation behavior.

## 0.1.4 — preview

- Added a skippable four-step native welcome with immediate theme, spacing and reduced-motion choices, a starting-page selection and Settings replay. Setup does not connect providers, download models or change routing or hardware controls.
- Added launch-page selection, last-page restoration, sidebar page visibility and optional sidebar badges. Home, Jobs and Settings remain accessible; hiding a page does not remove it as a valid destination.
- Replaced repeated sidebar movement buttons with drag targets and a Move menu. Expanded Telegram setup with explicit chat discovery, draft status and disconnect confirmation.
- Added independent Light/Dark palettes, four presets, common and advanced color controls, hex entry, palette undo and contrast checks. Theme edits redraw without remounting pages.
- Added prospective host send-completion timing for eligible Codex Responses streams. Exact response identity and usage counters bind supplemental measurements; tool waits between requests and explicitly counted reasoning tokens are excluded. Historical missing clocks remain unknown, and response averages stay separate.
- Added an actionable provider-credential message for routed HTTP 401 responses without retrying or switching providers.
- Simplified Statistics cost presentation with a short state summary and View prices control. Empty usage, missing prices and partial estimates are distinguished without a repeated diagnostic-style header.
- Expanded the README with installation, first steps, local transcription, routing, cost estimates and configuration guidance.

## 0.1.3 — preview

- Fixed native Codex WebSocket probes aborting normal turns and compaction: the HTTP-only route now returns HTTP 426 for the exact Responses probe, and all routed catalog rows advertise HTTP transport.
- Ordered the documented CommandCode DeepSeek reasoning choices Low/High/Max while retaining High as the independent default.

## 0.1.2 — preview

- Added window-free Codex routing status, connect and restore commands. An explicit bounded idle wait uses the existing journal-aware handoff and preserves active requests and independently changed settings.
- Documented one maintained public source for local installations while retaining private runtime storage and preserved older checkouts.
- Added a catalog regression for replacing a bridge's stale None-only DeepSeek row with the native model-specific High/Low/Max choices. Existing Codex/T3 Code metadata must be refreshed after native handoff; installing a bundle alone does not change an active bridge's catalog.
- Fixed missing required reasoning-preset descriptions that caused Codex 0.165.0 to reject the entire native catalog. Added strict consumer-contract coverage and validated the correction against an actual Codex client.

## 0.1.0 — preview

- Native macOS workspace with 14 pages for providers, coding, benchmarks, statistics, transcription and Mac utilities.
- MIT-licensed public source with retained third-party license notices.
- Source-build documentation for the pinned macOS 26.5 SDK, native SwiftPM and two compiler jobs/backend threads.
- Minimum deployment target of macOS 14; validation on macOS 27.2/arm64. macOS 14 runtime behavior, Intel and universal build validation remain pending.
- Bring-your-own providers, optional coding-tool integrations and native background work that survives normal Quit.
- Local Whisper model install/remove UI for `large-v3-turbo` Q5: 574,041,195 bytes (about 574 MB), with no Wispr login or cloud transcription credentials.
- Native WAV/MP3/M4A decoding, optional ffmpeg fallback and optional yt-dlp for links.
- One Whisper child per transcription job, with model memory released on child exit; no always-on Whisper process.
- Explicit window-free CLI for model status/install/remove and local file transcription, sharing the model store and owned Whisper child.
- Completed static CLI build from pinned official whisper.cpp v1.9.4 source; model weights remain a separate optional download.
- Passed native Core/Presentation verification: 1,176 tests, zero failures, including the 50-test transcription/settings subset. Python packaging, installer and pricing fixtures: 57 tests, zero failures.
- The final packaged app passed real local CLI checks for model installation, transcription, cross-process lease protection, cancellation (exit 130), removal (exit 0) and child cleanup; test weights were removed afterward.
- Local hooks check staged secrets before commit and the public source boundary before push; full native tests remain a separate validation step.

- Final arm64 package: all five executable headers specify macOS 14 minimum and SDK 26.5; ad-hoc signed, not notarized. No Intel/universal binary.
- Six visually reviewed native page illustrations for Statistics, Transcribe and Settings in Light/Dark, captured quietly with empty fixtures. These are not full-shell or compositor captures.
- Transcription notifications default to off, a missing Transcribe icon is corrected, and the sidebar width control uses a continuous slider.

### Remaining limits

Fresh-user installation acceptance is pending. macOS 14 runtime, Intel/universal builds, all app job flows, optional media/link integrations and hardware controls are not established by these checks. See [validation scope](docs/VALIDATION.md) and [installation](docs/INSTALL.md) for the final package checksum and constraints.
