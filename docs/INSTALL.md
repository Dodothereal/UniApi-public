# Installation

## Requirements

- A Mac running macOS 14 or later. Validation has run on macOS 27.2/arm64. Runtime behavior on macOS 14, Intel builds and universal builds remains unverified.
- For a source build: Apple's developer tools with the macOS 26.5 SDK and a matching Swift toolchain, Python 3, CMake and Make. The Whisper build also uses curl and tar supplied by macOS.
- Additional tools and accounts only for the integrations you choose to use.

The SDK pin is a build requirement, separate from the macOS 14 deployment target. A newer SDK is not an equivalent substitution for this preview.

## Build from source

From the repository root:

```sh
bash native/swift/build.sh
```

The script selects the pinned SDK and matching compiler, uses native SwiftPM with two compiler jobs and two backend threads, and stages `native/swift/build.noindex/UniApi Native.app`. It also builds and bundles `uniapi-whisper`. It does not download model weights, run inference, install the app or restart services. The default build is ad-hoc signed.

Install CMake before building and ensure `cmake` and `make` are available in your shell. For example, if you already use Homebrew:

```sh
brew install cmake
```

The Whisper helper uses [official whisper.cpp v1.9.4 source](https://github.com/ggml-org/whisper.cpp/tree/v1.9.4), downloaded from the [pinned upstream archive](https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.9.4). `tools/build-local-whisper.sh` verifies its pinned SHA-256, then builds `whisper-cli` with CMake and two build jobs. Compiler file, macro and debug prefix maps replace both logical and physical spellings of local source/build roots with `whisper.cpp` and `whisper-build`, including assertion paths in the Metal Objective-C sources; they preserve ordinary string literals. Source paths containing spaces are quoted. Existing C/C++ flags are preserved, and CMake updates the flags file each object depends on, rebuilding stale objects when the remapping flags change. The build refuses to publish a helper that still contains local build roots or personal home paths. Whisper/ggml libraries are linked statically, Metal source is embedded, and only macOS system dynamic dependencies are permitted. The build targets the current host architecture; it does not produce a universal binary.

The upstream CLI static build has completed, and real local CLI transcription and model lifecycle checks have passed. The final 0.1.0 packaged executable passed real local CLI transcription and model lifecycle checks; app job flows and optional integrations need their own runtime evidence. CMake and Make are source-build tools, not transcription runtime requirements.

If discovery fails, set `UNIAPI_SWIFT_SDK` to your installed `MacOSX26.5.sdk` directory and `UNIAPI_SWIFT_TOOLCHAIN` to the matching `swift` executable, then rerun the script. Do not remove the SDK check to work around a missing toolchain.

Building is the supported starting point. The final 0.1.0 arm64 package has been built and checked without model weights. Fresh-user installation validation remains pending. A staged bundle is not proof that an installer or every integration is ready. Review [Configuration](CONFIGURATION.md) before launching against existing data. Use the preview's reviewed installer rather than manually replacing an existing installation.

## Optional transcription tools

Local WAV, MP3 and M4A files use the native decoder without ffmpeg. Install ffmpeg for formats that decoder cannot read, and yt-dlp if you want to transcribe links. With an existing Homebrew setup, install only the tools you need:

```sh
brew install ffmpeg
brew install yt-dlp
```

The app searches its process PATH, the user's `.local/bin`, and standard Homebrew locations. For another installation method, make the executable available in one of those locations. Link handling also depends on the source site; downloaded media may need ffmpeg for decoding. No blanket site or format compatibility is claimed.

Install the optional 574 MB model separately using **Install model** in Transcribe or the explicit `UniApiNative --local-model install` command. See [Configuration](CONFIGURATION.md#local-transcribe) for provenance, removal and process lifetime, and [window-free CLI examples](CONFIGURATION.md#command-line-without-a-window). Status and file-transcription commands never download a missing model implicitly.

## Release downloads

Use the [latest preview release](https://github.com/Dodothereal/UniApi-public/releases/latest) and its exact versioned checksum and validation assets. The table below preserves the original 0.1.0 artifact record; its byte counts and checksum do not apply to newer packages.

Download `UniApi-macos-0.1.0.zip` from the [v0.1.0 preview release](https://github.com/Dodothereal/UniApi-public/releases/tag/v0.1.0).

| Artifact | 0.1.0 preview |
| --- | --- |
| ZIP size | 12,111,594 bytes |
| Architecture | arm64 only; no Intel/universal binary |
| Signing | Ad-hoc signed; no Developer ID or notarization |
| Executable headers | All five executables: macOS 14 minimum, SDK 26.5 |
| Runtime validation host | macOS 27.2, arm64 |
| Model weights | Not included; explicit optional download |

ZIP SHA-256:

```text
0542561f9d85d82399aea9798bc2adf2614b1a868831430e6730b69a710e8dac
```

Before extracting, compare the archive's SHA-256 with the checksum published for that exact asset:

```sh
shasum -a 256 "UniApi-macos-0.1.0.zip"
```

Use the actual archive filename for the release you downloaded. Continue only if all 64 hexadecimal characters match. A matching checksum detects file changes; a checksum distributed alongside an archive does not independently establish its publisher.

Preview 0.1.0 is ad-hoc signed and not notarized. Gatekeeper may block a downloaded app. After checking its source and checksum, use macOS System Settings > Privacy & Security > Open Anyway if macOS offers it and you choose to proceed. Follow [Apple's guidance for opening apps safely](https://support.apple.com/en-us/102445), and proceed only if you trust the source and are confident the app has not been tampered with. Do not disable Gatekeeper globally or recursively remove quarantine attributes. If macOS reports damage or malware, stop and report the exact warning with the release version.

## Explicit installation

After verifying and extracting the archive, open a terminal in its `UniApi-macos-0.1.0` directory. Finish running and queued work in any existing installation and use normal Quit to dismiss its presentation. Review the packaged `INSTALL.md`, then run:

```sh
./install.sh --plan
```

This performs read-only preflight. If the plan admits installation and you choose to install, run:

```sh
./install.sh --install
```

The installer preserves data/providers and backs up the prior app and service definitions. Do not bypass a refusal. Automatic rollback requires verified idle ownership and successful retirement of candidate services; if that proof fails, the candidate and backup remain and recovery is reported incomplete. Packaging/installer fixture tests are not evidence of a successful real fresh-user install.

## Background work and updates

Normal Quit hides the presentation while background work continues. Closing the window also does not establish that services stopped.

For an update, let active jobs and coding turns finish, use normal Quit to dismiss the presentation, then let the installer perform its ownership and idle-state checks. The installer must refuse conflicting owners or active work. Do not bypass these checks, kill another installation's processes, or launch a second owner against the same data.

A full stop requires an explicit operation that verifies ownership for that installation. This preview does not document a general stop/uninstall command; do not substitute blanket process kills or service removal. Removing an app bundle alone does not prove background services stopped or remove saved data. Back up your configuration and data before an update or removal.
