# Local development from one source

Use this public checkout as the canonical source for the app you run locally.
Make future fixes, tests and documentation changes here, review them here, and
build the installed app from the reviewed revision. An earlier private checkout
can remain a preserved archive. Do not maintain matching changes in two repos.

This workflow does not require renaming, moving or deleting the old checkout,
purging its history, or importing its private history into this repository.
Source ownership and runtime storage are separate choices.

## Source, installed app and private state

| Location | Role |
| --- | --- |
| This public checkout | Canonical maintained source, tests and public documentation |
| `native/swift/build.noindex/` and `dist/` in this checkout | Generated candidate bundles and packages; not runtime storage |
| `$HOME/Applications/UniApi.app` | Stable installed production bundle |
| Existing `UNIAPI_ROOT` | Retained runtime anchor and service working directory; may still be `$HOME/UniApi` |
| Existing `UNIAPI_DATA` | Database, jobs, transcripts, usage history, benchmark state and logs |
| Existing `UNIAPI_PROVIDERS` | Private provider configuration, including credentials |
| Earlier private checkout | Preserved source archive; any existing runtime directories inside it stay in place |

The two LaunchAgents pin the existing installation's locations. Keeping
`UNIAPI_ROOT` pointed at an older checkout does not mean that checkout must
remain a second maintained source: the native services execute the installed
bundle and its bundled helpers. Keep optional external tools available at their
configured locations as well.

Read the storage keys in both existing definitions before planning an update:

```sh
for uniapi_label in app.devved.uniapi-server app.devved.uniapi-shim; do
  uniapi_definition="$HOME/Library/LaunchAgents/$uniapi_label.plist"
  for uniapi_key in UNIAPI_ROOT UNIAPI_DATA UNIAPI_PROVIDERS; do
    printf '%s %s: ' "$uniapi_label" "$uniapi_key"
    plutil -extract "EnvironmentVariables.$uniapi_key" raw -o - "$uniapi_definition"
  done
done
```

These commands read storage paths, not provider credentials. Keep their actual
output private. If an override is absent, inspect the definition's
`WorkingDirectory` and the [runtime defaults](CONFIGURATION.md#data-locations).
Do not guess a new location. In particular, `UNIAPI_PROVIDERS` need not be inside
`UNIAPI_DATA`; the default is `providers.json` under `UNIAPI_ROOT`.

Never copy private configuration, databases, transcripts, operator receipts,
logs, preferences, model weights or old source archives into the public checkout.
An ignore rule is not permission to publish them. Use synthetic fixtures and
sanitized evidence for review, and keep backups outside this source tree.

## Make and check a change

Work from this checkout's root on a focused branch. Read [AGENTS.md](../AGENTS.md)
and [Contributing](../CONTRIBUTING.md), inspect the worktree, and preserve other
contributors' edits. Commit source and documentation together in logical units;
obtain independent review before merging. Build the reviewed revision from this
checkout rather than copying changed files back to the archive.

Use the checks appropriate to the change. For native implementation changes,
the normal gate and app build are:

```sh
bash native/swift/tools/verify-ci.sh
bash native/swift/build.sh
python3 tools/scan_secrets.py
```

These commands do not install the app or restart its services. The build uses
the pinned macOS 26.5 SDK/toolchain, native SwiftPM, two compiler jobs and two
backend threads. It also needs CMake and Make for the pinned Whisper helper;
see [build setup](INSTALL.md#build-from-source). The Whisper source archive may
be fetched during a build. Model weights and inference are separate explicit
actions. Coordinate builds with other workers: the SwiftPM intermediates are
shared within this checkout even when bundle output directories differ.

The default build stages `UniApi Native.app` with bundle identifier
`app.devved.uniapi.native-development`. It is not an installable replacement for
the production app. A different bundle identifier also does not isolate runtime
storage or ownership. Do not launch a development candidate as a second writable
owner against the installed app's data. Tests must use isolated fixtures;
production runtime validation needs its own coordinated window.

## Stage a production candidate

Choose the version for the reviewed candidate explicitly; the following uses
the preview version as an example:

```sh
UNIAPI_NATIVE_CONFIGURATION=release \
UNIAPI_NATIVE_BUNDLE_VARIANT=production \
UNIAPI_NATIVE_VERSION=0.1.0 \
bash native/swift/build.sh
```

This stages `native/swift/build.noindex/UniApi.app`, with the preserved production
identity `app.devved.uniapi.hub`. It does not install it. The installer checks
the production identity and signature; it refuses the development bundle.
Version numbers alone do not prove data compatibility or preservation.

For a distributable candidate, the native packager builds a production bundle
from this same source using its own temporary bundle output directory:

```sh
python3 tools/package_release.py --platform macos --version 0.1.0
```

The resulting `dist/UniApi-macos-0.1.0/` contains `UniApi.app`, `install.sh`,
`tools/install-native.sh`, `INSTALL.md` and `LICENSE`. The ZIP and its checksum
are written beside that directory. The bundle carries five executables:
`UniApiNative`, `uniapi-shim`, `uniapi-fans`, `uniapi-battery` and
`uniapi-whisper`, plus the exact admitted resources, empty provider example and
license notices. It carries no operator data, model weights or Node/web server.
See [release installation](INSTALL.md#release-downloads) for checksum, signing
and platform limits. Packaging does not publish a release.

## Plan, then explicitly install

The installation's owner coordinates the fresh private backup, idle window,
guarded install and preservation checks. Documentation or build work is not
permission to install. Before an authorized update, finish running and queued
jobs and active coding turns, then use normal Quit. Closing the window alone
can leave the GUI owner in a state that admission refuses. Keep other tools'
active requests and hardware intent under their existing owners.

Run the source installer from this checkout's root, selecting the exact reviewed
production candidate:

```sh
UNIAPI_NATIVE_APP_SOURCE="$PWD/native/swift/build.noindex/UniApi.app" \
bash native/swift/tools/install-native.sh --plan
```

Start with no conflicting storage overrides in the calling shell. The installer
imports the existing LaunchAgents' `UNIAPI_ROOT`, `UNIAPI_DATA`,
`UNIAPI_PROVIDERS`, `CODEX_HOME`, `ZCODE_HOME` and `XDG_DATA_HOME` where present,
and refuses conflicting requested paths. Do not set `UNIAPI_ROOT` to this public
checkout just because it now supplies the source. Also inspect any
`UNIAPI_NATIVE_APP_SOURCE`, `UNIAPI_NATIVE_HOME`, `UNIAPI_NATIVE_APPLICATIONS`
or `UNIAPI_NATIVE_LAUNCH_AGENTS` overrides before using a command intended for
the standard installed app.

`--plan` performs read-only admission without constructing an app runtime or
retiring services. For an existing native installation, expect `kind: native`,
`status: prepared` and `canPrepare: true` on success. `safeToInstall: false` is
expected at this stage: actual retirement still has to prove exclusive idle
ownership. A successful plan is not a backup or a completed update.

After the owner has verified the backup, reviewed the candidate and plan, and
authorized the update, the corresponding guarded command is:

```sh
UNIAPI_NATIVE_APP_SOURCE="$PWD/native/swift/build.noindex/UniApi.app" \
bash native/swift/tools/install-native.sh --install
```

For a verified extracted package, use its `./install.sh --plan` and then, when
authorized, `./install.sh --install` instead. That wrapper selects the adjacent
production `UniApi.app`; it uses the same guarded installer. Keep the selected
candidate unchanged between review, plan and installation.

The installer rechecks ownership, app bytes, launch definitions and active work
before replacement. A native update preserves the existing LaunchAgent settings
and environment except for a fresh installation nonce, and confirms both new
services against that identity. Linked paths, conflicting owners, active work,
changed definitions or unavailable ownership evidence can block it. Do not
bypass a refusal, manually replace the bundle, or force-stop services.

## Preservation and intentional behavior changes

| Area | Upgrade expectation and limit |
| --- | --- |
| Providers | `NativeProviderStore.seedIfAbsent` validates an existing provider file and leaves it in place. Seeding applies only to an absent file, using `UNIAPI_ROOT/providers.example.json` if present, otherwise the bundled example. Never copy the public empty example over live configuration. |
| Database and history | The installer does not replace the data directory or initialize a separate empty store. Runtime schema migrations and normal background writes still apply; retain a coherent backup and compare prior durable records after installation. |
| Preferences | Production retains the bundle/defaults identity. Existing destination values win in preference migration. A new fallback default does not erase an explicitly saved value. |
| Transcription | Public production uses local Whisper (`localASR`) instead of the older Wispr production path, and does not read another app's authentication store. Existing saved transcripts and chunk checkpoints are retained. New transcription requires the separately installed optional model; old Wispr throughput and quality results do not establish local Whisper behavior. Finish active transcription before updating. |
| Notifications | The old private `.claude/.env` credential fallback is removed. Delivery requires explicit app-owned configuration in `$HOME/Library/Application Support/UniApi/notifications.json`, saved in Settings. The per-transcript fallback changes from on to off; an already saved preference remains, but cannot enable delivery without app-owned credentials and opt-in. Legacy credentials are not deleted or imported. Arena completion delivery uses the same opt-in store. |
| Schedules and hardware | Existing saved schedules and control intent remain; an empty fresh-install default does not disable a saved schedule. Scheduled work may become due after startup, so an idle preflight does not guarantee the candidate stays idle for rollback. Privileged helper installation remains a separate explicit action. |

The ASR and notification changes are functional changes, not a provider or
history wipe. No reset of existing provider configuration or transcript history
is performed by those defaults. Nevertheless, retaining filenames does not prove
that every historical row or setting survived a particular installation.

The installer's recovery directory under `UNIAPI_DATA/native-install-backups/`
holds the prior app and service definitions plus private recovery evidence. It
is not a database/configuration backup, and automatic app rollback is not a
database rollback. The owner must separately back up configuration, a coherent
SQLite snapshot and related private data, installed bundle, service definitions
and relevant preferences before updating. Copying only the main database file
while WAL writes are active is not a coherent backup.

If candidate retirement cannot prove safe idle ownership, rollback deliberately
leaves the candidate and backups in place and reports incomplete recovery. Keep
those private records and coordinate recovery; do not overwrite new data with
an old database or relaunch an archived source tree against the live store.

After a successful guarded update, verify prior providers, durable history,
preferences and hardware intent and the new services' startup identities. Keep
machine-specific receipts and any private archive handoff pointer outside this
public source. Only then record local installation success; a build, fixture
suite or prepared plan alone cannot establish it.
