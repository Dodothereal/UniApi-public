# UniApi public development

- No emojis in code, UI, documentation or communication.
- This is the clean public native macOS source tree. Never copy private operator data, credentials, history, caches, receipts or local build artifacts into it.
- Keep providers user-supplied. Local transcription must not read another app's authentication store.
- Preserve other workers' edits and use explicit, disjoint ownership.
- Keep UI, platform, security and user-facing documentation consistent with changes.
- Use the pinned SDK/toolchain and two compiler jobs/backend threads. Do not install or interrupt running services during a build or test.
- Keep signing, runtime, architecture and fresh-user evidence distinct; do not claim untested support.
- Use local reviewed branches; do not publish a remote or release until the clean candidate is reviewed and ready.
