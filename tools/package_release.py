#!/usr/bin/env python3
"""Build an installable UniApi release package for macOS or Windows.

WHAT A PACKAGE IS
-----------------
macOS packages the native Swift app and its three Swift helpers, with explicit
preflight/installation infrastructure. It carries no Node server, React client,
Python shim, dependency folders or operator data. --legacy-web explicitly
packages the retained historical macOS implementation. Windows retains the
existing web package and optional external integrations.

WHAT IS DELIBERATELY LEFT OUT
-----------------------------
providers.json (live API keys), data/ (transcripts, jobs, benchmark history),
node_modules, the git history and the legacy Swift app. The package ships
providers.example.json; the installer copies it into place, owner-only.

USAGE
    python3 tools/package_release.py --platform macos   --version 2.0.0
    python3 tools/package_release.py --platform windows --version 2.0.0
    python3 tools/package_release.py --platform windows --version 2.0.0 --skip-client-build

Output: dist/UniApi-<platform>-<version>.zip and a .sha256 next to it.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import zipfile
import re
from pathlib import Path
import tempfile

# Import the same exact resource admission used by the bundle builder.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from native_manifest import validate_app, validate_package

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")

# Everything the server needs to run from source, and nothing that holds state.
INCLUDE_DIRS = [
    "server/src",
    "server/test",
    "client/dist",
    "proxy",
    "tools",
    "docs",
    "shell/windows",
    "shell/launchd",
    "assets",
    "native/fans",
    "native/battery",
    "native/activity",
    "arena",
]
INCLUDE_FILES = [
    "package.json",
    "pnpm-lock.yaml",
    "pnpm-workspace.yaml",
    "server/package.json",
    "server/tsconfig.json",
    "client/package.json",
    "client/tsconfig.json",
    "client/vite.config.ts",
    "client/index.html",
    "providers.example.json",
    "README.md",
    "CLAUDE.md",
    "LICENSE",
]
# Never staged, whatever else matches.
DENY_NAMES = {"providers.json", ".env", ".DS_Store"}
DENY_DIRS = {"node_modules", "data", "__pycache__", "build.noindex", ".git"}


def run(cmd, cwd=ROOT, check=True):
    print("  $ %s" % " ".join(cmd))
    r = subprocess.run(cmd, cwd=cwd)
    if check and r.returncode != 0:
        sys.exit("command failed: %s" % " ".join(cmd))
    return r.returncode


def stage_tree(stage):
    """Copy the include list into `stage`, filtering the deny list."""
    def ignore(_dir, names):
        # A package carries the ledger's README and directory, never one
        # machine's local result files.
        in_ledger = os.path.basename(_dir) == "results" and os.path.basename(os.path.dirname(_dir)) == "arena"
        return [n for n in names if n in DENY_DIRS or n in DENY_NAMES or n.endswith(".pyc") or (in_ledger and n.endswith(".json"))]

    for rel in INCLUDE_DIRS:
        src = os.path.join(ROOT, rel)
        if not os.path.isdir(src):
            print("  (skip missing dir %s)" % rel)
            continue
        shutil.copytree(src, os.path.join(stage, rel), ignore=ignore, dirs_exist_ok=True)

    for rel in INCLUDE_FILES:
        src = os.path.join(ROOT, rel)
        if not os.path.isfile(src):
            print("  (skip missing file %s)" % rel)
            continue
        dst = os.path.join(stage, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)


def assert_no_secrets(stage):
    """A release must never carry a credential. This is the last gate before
    the zip closes, and it is intentionally the same scanner the pre-push hook
    uses so 'clean' means one thing in this repo."""
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    from scan_secrets import scan_text, should_skip

    findings = []
    for dirpath, dirs, files in os.walk(stage):
        dirs[:] = [d for d in dirs if d not in DENY_DIRS]
        for f in files:
            full = os.path.join(dirpath, f)
            # SKIP_DIRS in scan_secrets.py are forward-slash prefixes, so a
            # Windows packaging run would not skip client\dist and friends.
            rel = os.path.relpath(full, stage).replace(os.sep, "/")
            if should_skip(rel):
                continue
            try:
                with open(full, encoding="utf-8", errors="replace") as fh:
                    findings.extend(scan_text(fh.read(), rel))
            except OSError:
                continue
    if findings:
        print("\nREFUSING TO PACKAGE - credentials in the staged tree:", file=sys.stderr)
        for f in findings:
            print("  %s" % f, file=sys.stderr)
        sys.exit(2)
    print("  secret scan of the staged tree: clean")


def write_install_readme(stage, platform, version):
    if platform == "macos":
        body = """# UniApi %s for macOS

## Install

    ./install.sh

That installs the LaunchAgents for the server and the shim, copies UniApi.app
into ~/Applications, and opens the app. Requires Node 22.5+ (24 recommended),
pnpm, and Python 3 - the installer tells you if one is missing.

## First run

The app opens on the Home page with no providers configured. Add your API keys
under Settings; they are stored in providers.json next to this file, mode 600,
in plain text (by design - these are free-tier keys the UI lets you copy).

## Uninstall

    ./uninstall.sh

Your providers.json and data/ are left alone.
"""
    else:
        body = """# UniApi %s for Windows

## Install

Right-click `install.ps1` and choose "Run with PowerShell", or from a terminal:

    powershell -ExecutionPolicy Bypass -File install.ps1

That registers two Scheduled Tasks (the server and the Claude Code shim) to
start at logon, creates Start Menu and Desktop shortcuts, and opens the app.

Requires Node 22.5+ (24 recommended) and Python 3. Install Node from
nodejs.org and Python from python.org with "Add python.exe to PATH" ticked;
pnpm is set up for you through corepack.

## What the window is

Windows has no WebKit shell, so the app window is a Chromium app window
(Edge, which ships with Windows) pointed at the local server, with its own
profile and no browser chrome. The whole UI is a normal web app, so
http://127.0.0.1:8780 works in any browser too.

## First run

Add your API keys under Settings. They are stored in providers.json next to
this file, restricted to your user account, in plain text (by design).

## Uninstall

    powershell -ExecutionPolicy Bypass -File uninstall.ps1

Your providers.json and data\\ are left alone.
"""
    with open(os.path.join(stage, "README-INSTALL.md"), "w", encoding="utf-8") as fh:
        fh.write(body % version)


def build_macos(stage):
    """Build the AppKit shell and stage the bundle plus a LaunchAgent installer."""
    print("== building the macOS window shell")
    run(["/bin/zsh", os.path.join(ROOT, "shell", "build.sh"), "--no-install"])
    shutil.copy2(os.path.join(ROOT, "data", "bin", "uniapi-fans"), os.path.join(stage, "native", "fans", "uniapi-fans"))
    shutil.copy2(os.path.join(ROOT, "data", "bin", "uniapi-battery"), os.path.join(stage, "native", "battery", "uniapi-battery"))
    shutil.copy2(os.path.join(ROOT, "data", "bin", "uniapi-activity"), os.path.join(stage, "native", "activity", "uniapi-activity"))
    app = os.path.join(ROOT, "shell", "build.noindex", "UniApi.app")
    if not os.path.isdir(app):
        sys.exit("shell/build.sh did not produce UniApi.app")
    shutil.copytree(app, os.path.join(stage, "UniApi.app"), symlinks=True)

    installer = """#!/bin/zsh
# UniApi macOS installer. Idempotent.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "== checking prerequisites"
command -v node >/dev/null || { echo "Node 22.5+ is required: https://nodejs.org" >&2; exit 2 }
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" -ge 22 ] || { echo "Node $NODE_MAJOR is too old (need 22.5+ for node:sqlite)" >&2; exit 2 }
command -v pnpm >/dev/null || { corepack enable pnpm 2>/dev/null || { echo "pnpm is required: npm i -g pnpm" >&2; exit 2 } }
command -v python3 >/dev/null || echo "warning: python3 not found - the Claude Code shim and the benchmark need it"

if [ ! -f "$HERE/providers.json" ]; then
  cp "$HERE/providers.example.json" "$HERE/providers.json"
  chmod 600 "$HERE/providers.json"
  echo "== created providers.json (add your keys in the app under Settings)"
fi

echo "== installing dependencies"
cd "$HERE" && pnpm install --frozen-lockfile

echo "== installing the fan, battery and Activity helpers"
mkdir -p "$HERE/data/bin"
cp "$HERE/native/fans/uniapi-fans" "$HERE/data/bin/uniapi-fans"
chmod 755 "$HERE/data/bin/uniapi-fans"
cp "$HERE/native/battery/uniapi-battery" "$HERE/data/bin/uniapi-battery"
chmod 755 "$HERE/data/bin/uniapi-battery"
cp "$HERE/native/activity/uniapi-activity" "$HERE/data/bin/uniapi-activity"
chmod 755 "$HERE/data/bin/uniapi-activity"

echo "== installing the app"
rm -rf "$HOME/Applications/UniApi.app"
mkdir -p "$HOME/Applications"
cp -R "$HERE/UniApi.app" "$HOME/Applications/UniApi.app"
# Adhoc signature: required on Apple Silicon for a locally built bundle.
codesign --force --deep --sign - "$HOME/Applications/UniApi.app" 2>/dev/null || true

echo "== installing the background services"
UNIAPI_ROOT="$HERE" "$HERE/shell/launchd/install-server.sh"

echo ""
echo "UniApi is installed. Opening it now."
open "$HOME/Applications/UniApi.app"
"""
    p = os.path.join(stage, "install.sh")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(installer)
    os.chmod(p, 0o755)

    uninstaller = """#!/bin/zsh
# Removes the LaunchAgents and the app bundle. Leaves providers.json and data/.
set -e
for L in app.devved.uniapi-server app.devved.uniapi-shim; do
  launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$L.plist" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$L.plist"
  echo "removed $L"
done
rm -rf "$HOME/Applications/UniApi.app"
echo "removed ~/Applications/UniApi.app"
echo "providers.json and data/ were left in place."
"""
    p = os.path.join(stage, "uninstall.sh")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(uninstaller)
    os.chmod(p, 0o755)


def build_windows(stage):
    """Hoist the Windows scripts to the top level so the package is one click."""
    for name in ("install.ps1", "uninstall.ps1", "launch.ps1", "UniApi.vbs"):
        src = os.path.join(ROOT, "shell", "windows", name)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(stage, name))
    # The hoisted copies sit at the package root, one level shallower than in
    # the repo, so they must resolve the root differently.
    for name in ("install.ps1", "uninstall.ps1", "launch.ps1"):
        p = os.path.join(stage, name)
        if not os.path.exists(p):
            continue
        with open(p, encoding="utf-8") as fh:
            text = fh.read()
        text = text.replace("Join-Path $PSScriptRoot '..\\..'", "$PSScriptRoot")
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(text)


def make_zip(stage, out_path, top):
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for dirpath, dirs, files in os.walk(stage):
            dirs[:] = [d for d in dirs if d not in DENY_DIRS]
            for f in sorted(files):
                full = os.path.join(dirpath, f)
                arc = os.path.join(top, os.path.relpath(full, stage))
                info = zipfile.ZipInfo.from_file(full, arc)
                # Preserve the executable bit: an install.sh that unzips without
                # +x is a support ticket. ZipInfo carries the mode in the high
                # bits of external_attr.
                mode = os.stat(full).st_mode
                info.external_attr = (mode & 0xFFFF) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(full, "rb") as fh:
                    z.writestr(info, fh.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", required=True, choices=["macos", "windows"])
    ap.add_argument("--version", required=True)
    ap.add_argument("--skip-client-build", action="store_true")
    ap.add_argument("--legacy-web", action="store_true", help="explicitly package the retained web macOS implementation")
    args = ap.parse_args()

    version = args.version.lstrip("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        sys.exit("version must be three numeric components")
    if args.platform == "macos" and not args.legacy_web:
        return package_native_macos(version)
    name = "UniApi-%s-%s" % (args.platform, version)
    stage = os.path.join(DIST, name)

    if os.path.exists(stage):
        shutil.rmtree(stage)
    os.makedirs(stage, exist_ok=True)

    if not args.skip_client_build:
        print("== building the client")
        run(["pnpm", "exec", "vite", "build"], cwd=os.path.join(ROOT, "client"))
    if not os.path.exists(os.path.join(ROOT, "client", "dist", "index.html")):
        sys.exit("client/dist/index.html is missing - build the client first")

    print("== staging %s" % name)
    stage_tree(stage)
    write_install_readme(stage, args.platform, version)

    if args.platform == "macos":
        build_macos(stage)
    else:
        build_windows(stage)

    print("== verifying the package carries no credentials")
    assert_no_secrets(stage)

    out = os.path.join(DIST, name + ".zip")
    if os.path.exists(out):
        os.remove(out)
    print("== zipping")
    make_zip(stage, out, name)

    digest = hashlib.sha256(open(out, "rb").read()).hexdigest()
    with open(out + ".sha256", "w", encoding="utf-8") as fh:
        fh.write("%s  %s\n" % (digest, os.path.basename(out)))

    size_mb = os.path.getsize(out) / 1e6
    print("\n%s  (%.1f MB)" % (os.path.relpath(out, ROOT), size_mb))
    print("sha256 %s" % digest)
    return 0


def sha256_stream(source):
    """Bound archive hashing memory and retain macOS Python 3.9 compatibility."""
    digest = hashlib.sha256()
    while True:
        chunk = source.read(1 << 20)
        if not chunk:
            return digest.hexdigest()
        digest.update(chunk)


def package_native_macos(version):
    """The macOS product contains native executables and install infrastructure,
    never the legacy web tree, dependency folders or operator runtime data."""
    name = "UniApi-macos-" + version
    stage = os.path.join(DIST, name)
    environment = os.environ.copy()
    environment.update(UNIAPI_NATIVE_CONFIGURATION="release", UNIAPI_NATIVE_BUNDLE_VARIANT="production", UNIAPI_NATIVE_VERSION=version)
    # Resolve exactly the CI-compatible SDK/toolchain before staging anything.
    discovery = subprocess.run(["bash", "native/swift/tools/swift-environment.sh"], cwd=ROOT, env=environment,
                               capture_output=True, text=True, check=True)
    selection = discovery.stdout.splitlines()
    if len(selection) != 2:
        raise RuntimeError("Native SDK discovery returned an invalid selection")
    environment.update(UNIAPI_SWIFT_SDK=selection[0], UNIAPI_SWIFT_TOOLCHAIN=selection[1])
    os.makedirs(DIST, exist_ok=True)
    if os.path.exists(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)
    # A simultaneous build cannot replace the bundle selected for this package.
    with tempfile.TemporaryDirectory(prefix=".native-build-", dir=DIST) as build_root:
        environment["UNIAPI_NATIVE_BUILD_ROOT"] = str(Path(build_root).resolve())
        subprocess.run(["bash", "native/swift/build.sh"], cwd=ROOT, env=environment, check=True)
        app = os.path.join(build_root, "UniApi.app")
        validate_app(app, variant="production", version=version)
        shutil.copytree(app, os.path.join(stage, "UniApi.app"), symlinks=True)
    os.makedirs(os.path.join(stage, "tools"))
    shutil.copy2(os.path.join(ROOT, "native/swift/tools/install-native.sh"), os.path.join(stage, "tools/install-native.sh"))
    installer = os.path.join(stage, "install.sh")
    with open(installer, "w", encoding="utf-8") as output:
        output.write('#!/bin/bash\nset -euo pipefail\nbase="$(cd "$(dirname "$0")" && pwd)"\nexport UNIAPI_NATIVE_APP_SOURCE="$base/UniApi.app"\nexec bash "$base/tools/install-native.sh" "$@"\n')
    os.chmod(installer, 0o755)
    with open(os.path.join(stage, "INSTALL.md"), "w", encoding="utf-8") as output:
        output.write("# UniApi " + version + " for macOS\n\nRun `./install.sh --plan` for read-only preflight, then `./install.sh --install` for explicit transfer. Close the previous UniApi window first and finish running/queued work. The installer preserves data/providers and backs up the previous app and service definitions. Automatic rollback requires verified idle ownership and successful retirement of the candidate services. If that proof fails, including a loaded job without a running PID, the candidate and backup remain in place and recovery is reported incomplete. macOS 14 or newer is required. The app, shim, fan helper and charging helper are Swift; local transcription uses the bundled whisper.cpp runtime. Its optional 574 MB model is installed explicitly from Transcribe and runs only during jobs. External coding, media and browser integrations remain optional; no Node/Python server or web client is installed. Charging/fan privileged updates remain explicit in-app actions.\n")
    shutil.copy2(os.path.join(ROOT, "LICENSE"), stage)
    assert_native_stage(stage, version=version)
    assert_no_secrets(stage)
    archive = os.path.join(DIST, name + ".zip")
    make_zip(stage, archive, name)
    with open(archive, "rb") as source:
        digest = sha256_stream(source)
    with open(archive + ".sha256", "w", encoding="utf-8") as output:
        output.write(digest + "  " + os.path.basename(archive) + "\n")
    print(os.path.relpath(archive, ROOT), os.path.getsize(archive), "bytes; sha256", digest)
    return 0


def assert_native_stage(stage, version=None):
    validate_package(stage, version=version)


if __name__ == "__main__":
    sys.exit(main())
