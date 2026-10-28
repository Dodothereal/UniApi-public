# Contributing

This repository contains the native macOS public preview. Keep changes focused, documented and free of personal data. Read [AGENTS.md](AGENTS.md) before changing source.

## Workflow

1. Open an issue for a substantial behavior or architecture change, or explain the scope in your pull request.
2. Work on a branch and preserve unrelated changes. Keep implementation and documentation consistent.
3. Add focused regression coverage for behavior changes. State what was verified and what remains untested.
4. Submit a pull request for independent review. Resolve findings before merge; the author should not be the sole reviewer.

Do not add credentials, transcripts, local histories, personal paths, generated caches, installation records or build products. Use synthetic fixtures and sanitized native captures. Do not use emojis in source, UI or documentation.

## Validation

Use the pinned macOS 26.5 SDK and matching Swift toolchain. The native scripts use SwiftPM's native build system, two compiler jobs and two backend threads.

App builds also require CMake and Make for the pinned upstream Whisper helper; see [build setup](docs/INSTALL.md#build-from-source). Keep source and model pins, checksums and third-party notices consistent. Building the helper must not install weights or start inference.

Relevant repository commands are:

```sh
bash native/swift/tools/verify-ci.sh
bash native/swift/build.sh
python3 tools/scan_secrets.py
```

Run the checks appropriate to your change and report their actual results. The 0.1.4 onboarding/settings candidate passed 1,251 native tests and 57 Python fixture tests on macOS 27.2/arm64; contributors must validate their own changes rather than inherit those results. Never install, restart services or change hardware as a side effect of testing. Coordinate any necessary runtime validation separately with the installation's owner.

For UI changes, inspect actual native rendering and relevant accessibility behavior. README illustrations use complete production pages in offscreen viewports with empty or explicitly labeled synthetic fixtures and a documented capture-only session bypass. Preserve those labels; page bitmaps do not verify full-shell interaction or fresh-user installation. For platform changes, report the macOS version and architecture used. A successful arm64 build does not verify Intel, universal binaries, fresh-user installation or notarization.

## Local hooks

Enable the repository hooks for this checkout:

```sh
git config core.hooksPath .githooks
```

Pre-commit runs the staged secret scan. Pre-push runs `python3 tools/pentest.py --static` for the public source boundary. Neither hook runs the full native test suite; run that suite separately before review and use CI results for the submitted revision.

## Pull requests

Describe the problem, resulting behavior and scope. Include validation commands and outcomes, relevant sanitized captures, and remaining limitations. Update the README or configuration/install guides when behavior changes. Security fixes need regression coverage for the boundary being repaired.

## Licenses

Contributions are provided under the repository's [MIT license](LICENSE). Preserve third-party notices and identify new dependencies and their terms. Existing notices include:

- [Whisper runtime](native/swift/Resources/Whisper-LICENSE.txt)
- [Lucide icons](native/swift/Resources/Lucide-LICENSE.txt)
- [Zstandard license](native/swift/Sources/CZstd/LICENSE), [COPYING](native/swift/Sources/CZstd/COPYING) and [notice](native/swift/Sources/CZstd/NOTICE.md)
- [SMC research](native/fans/Resources/SMC-research-LICENSE.md)
- [ThermalForge](native/fans/Resources/ThermalForge-LICENSE.txt)

Optional model weights and separately installed tools retain their own licenses. Do not describe them as relicensed under UniApi's MIT license.
