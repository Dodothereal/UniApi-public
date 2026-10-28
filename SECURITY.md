# Security

UniApi is a native macOS public preview. There is no promised security-update window or independent security certification. Use the latest published preview and report the affected version precisely.

## Reporting a vulnerability

Do not post credentials, exploit details affecting users, or private data in a public issue. If this repository's Security tab offers private vulnerability reporting, use that channel. If it is unavailable, open a minimal issue requesting a private reporting channel without disclosing the vulnerability. No separate security email or response-time guarantee is published here.

A useful private report includes the affected version, macOS version and architecture, prerequisites, a minimal reproduction, expected impact and sanitized supporting evidence. Use a disposable configuration where possible.

## Data and trust boundaries

- Provider keys are locally stored as plaintext in `providers.json`. Protect the file and its backups. A configured provider receives the requests you send to it.
- Coding sessions can access files and execute tools under the permissions you grant. Review routes, workspace access and permission prompts.
- Logs, transcripts, usage history and screenshots may expose project names, local paths or prompt contents. Redact them before sharing; never upload an entire data directory for a bug report.
- Optional browser and vendor integrations have separate authentication stores. Do not copy their tokens or cookies into provider configuration or diagnostics.
- Telegram chat discovery runs only after an explicit Settings action. It contacts the fixed Telegram HTTPS endpoint with the supplied bot token, refuses redirects, bounds the response and does not acknowledge updates, change webhooks or send a test message. Credentials remain in app-owned private storage.
- Optional Codex stream-speed metadata contains response/model identifiers, counters and host timing, never prompt, output or tool-argument content. The owner-only bounded journal is supplemental to usage history; Statistics retains a bounded metadata tail and admits measurements only against matching records. Local identifiers can still be private.
- Local Whisper requires no cloud transcription credentials. Model download is explicit and checked against a pinned size and SHA-256; the CLI is built from checksum-pinned upstream source. Transcription runs in a child process rather than an always-on model service. Model downloads, link retrieval and optional provider summaries are separate network requests. Local CLI checks have exercised model installation, transcription, concurrent-use refusal, cancellation, removal and child-process cleanup. The final 0.1.0 packaged executable passed these checks, including cross-process model-lease protection. These checks are not an independent security audit.
- Hardware helpers and background-service installation change system behavior. Use explicit supported installation and owned-stop flows; do not bypass ownership or active-work barriers.

## Downloads

Check the SHA-256 for the exact release asset before opening it. Preview 0.1.0 is arm64 only, ad-hoc signed and not notarized. Ad-hoc signing does not establish a verified publisher identity. See [Installation](docs/INSTALL.md) for Gatekeeper guidance.

Report accidental credential exposure privately and revoke the affected credentials with their issuer. Deleting a public attachment does not revoke a key.
