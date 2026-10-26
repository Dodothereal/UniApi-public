#!/usr/bin/env python3
"""Prepare real empty native page illustrations; not full-shell acceptance.

Preparation source, not yet compile/runtime validated. No work happens unless
--execute is supplied. After a reviewed public build, for example:

  python3 tools/capture-public-screenshots.py --output /tmp/public-page-captures
  # Review the plan, then repeat with --execute when capture is authorized.

Only the three complete production page views are hosted, with their existing
NativePage scrolling containers at 1050x800 points. All UI sources are copied
exactly except the recorded Main.swift transforms below. No product file is
edited. Parent-built public Core/Presentation/CZstd objects are retained and
linked; this tool never rebuilds them, downloads a model or runs the app owner.

Inspect every PNG before publication. Only images/ is a publication candidate;
work/ contains local diagnostics and source-composition provenance. These are
unordered native bitmaps, not compositor screenshots, installation verification,
functional verification, or evidence of whole-shell layout parity.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import tempfile


SESSION_INITIALIZER = """    // Capture-only designated initializer, injected into this copied class.
    init(captureRuntime: NativeRuntime) {
        self.runtime = captureRuntime
        self.transcription = NativeTranscriptionService(runtime: captureRuntime)
        self.preferencesPrepared = true
        self.pageActive = true
    }

"""
SESSION_ANCHOR = "    init() {\n        do {\n            let paths = NativePaths.discover()"
LABEL = "Offscreen native page, empty fixture; capture-only session bypass"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def public_file(path, repo):
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(repo) or not resolved.is_file() or path.is_symlink():
        raise ValueError("Expected a regular file within the public checkout")
    return resolved


def compose_main(text):
    if text.count("\n@main\n") != 1 or text.count(SESSION_ANCHOR) != 1:
        raise ValueError("Main.swift changed: review the exact capture transforms")
    class_start = text.index("final class NativeAppSession: ObservableObject {")
    if text.index(SESSION_ANCHOR) < class_start:
        raise ValueError("Session initializer anchor is outside NativeAppSession")
    return text.replace("\n@main\n", "\n", 1).replace(
        SESSION_ANCHOR, SESSION_INITIALIZER + SESSION_ANCHOR, 1)


def execute(command, env, cwd, log, timeout):
    # Own a new process group; never signal an existing app or shared service.
    with log.open("wb") as output:
        process = subprocess.Popen(command, env=env, cwd=cwd, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
    if code:
        raise RuntimeError(f"Command exited {code}; inspect {log.name}")


def main():
    repo = Path(__file__).resolve().parents[1]
    native = repo / "native/swift"
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True, help="New output directory; never overwritten")
    parser.add_argument("--build-dir", type=Path, default=native / ".build" / f"{platform.machine()}-apple-macosx/release")
    parser.add_argument("--app-bundle", type=Path, default=native / "build.noindex/UniApi Native.app")
    parser.add_argument("--execute", action="store_true", help="Explicitly authorize compilation and the six isolated page captures")
    args = parser.parse_args()
    if not args.execute:
        print("Plan only: no compiler, runtime, downloads, installation or output writes.")
        print("With --execute: reuse public release objects, compile exact copied UI plus harness,")
        print("prepare six separate empty homes, then capture Statistics/Transcribe/Settings in Light/Dark.")
        print("Publication requires visual review; no runtime or quiet-state success is claimed yet.")
        return 0
    if platform.system() != "Darwin":
        raise ValueError("Native page capture requires macOS")
    build = args.build_dir.resolve(strict=True)
    if not build.is_relative_to((native / ".build").resolve()) or build.name != "release":
        raise ValueError("Use retained release objects from this public checkout")
    bundle = args.app_bundle.resolve(strict=True)
    if not bundle.is_relative_to(repo) or bundle.suffix != ".app":
        raise ValueError("Use a staged public app bundle from this checkout")
    description = json.loads(public_file(build / "description.json", repo).read_text())
    commands = {value["moduleName"]: value for value in description["swiftCommands"].values()}
    ui = commands["UniApi"]
    ui_sources = [public_file(Path(name), repo) for name in ui["sources"]]
    expected = set((native / "Sources/UniApi").rglob("*.swift"))
    if set(ui_sources) != expected:
        raise ValueError("Parent build does not describe all current UI sources")
    main_source = next(path for path in ui_sources if path.name.lower() == "main.swift")
    composed_main = compose_main(main_source.read_text())
    other = ui["otherArguments"]
    package = other[other.index("-package-name") + 1]
    sdk = Path(other[other.index("-sdk") + 1])
    target = other[other.index("-target") + 1]
    compiler = Path(ui["executable"])
    if sdk.name != "MacOSX26.5.sdk" or not sdk.is_dir() or "macosx14.0" not in target:
        raise ValueError("Expected pinned SDK 26.5 and macOS 14 deployment target")
    if os.environ.get("UNIAPI_SWIFT_TOOLCHAIN") and Path(os.environ["UNIAPI_SWIFT_TOOLCHAIN"]).with_name("swiftc") != compiler:
        raise ValueError("Configured compiler disagrees with parent build metadata")
    inputs = []
    for name in ("UniApiCore", "UniApiPresentation"):
        command = commands[name]
        for source in command["sources"]:
            public_file(Path(source), repo)
        inputs.extend(public_file(Path(name), repo) for name in command["objects"])
    inputs.extend(public_file(path, repo) for path in (build / "CZstd.build").glob("*.o"))
    if not inputs or not list((build / "CZstd.build").glob("*.o")):
        raise ValueError("Parent release object files are missing")
    helper = public_file(bundle / "Contents/Resources/Helpers/uniapi-whisper", repo)
    if not os.access(helper, os.X_OK):
        raise ValueError("Parent-built public Whisper helper is missing")
    info = plistlib.loads(public_file(bundle / "Contents/Info.plist", repo).read_bytes())
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    output = args.output.resolve()
    images = output / "images"; images.mkdir(mode=0o700)
    work = output / "work"; work.mkdir(mode=0o700)
    snapshot = work / "Sources"; snapshot.mkdir()
    provenance = {"kind": "exact-public-ui-with-capture-session-bypass", "label": LABEL,
        "transforms": [{"file": str(main_source.relative_to(repo)),
                        "removeOnce": "\n@main\n", "replaceWith": "\n"},
                       {"file": str(main_source.relative_to(repo)), "insertBeforeOnce": SESSION_ANCHOR,
                        "insert": SESSION_INITIALIZER}], "sources": {}, "retainedObjects": {},
        "modules": {}, "copiedResources": {"Helpers/uniapi-whisper": sha(helper)}}
    frozen_sources = []
    for source in ui_sources:
        destination = snapshot / ("CapturedMain.swift" if source == main_source else source.name)
        if source == main_source:
            destination.write_text(composed_main)
        else:
            shutil.copyfile(source, destination)
        provenance["sources"][str(source.relative_to(repo))] = {
            "originalSHA256": sha(source), "copiedSHA256": sha(destination)}
        frozen_sources.append(destination)
    harness = public_file(repo / "tools/PublicScreenshotHarness.swift", repo)
    frozen_harness = snapshot / harness.name; shutil.copyfile(harness, frozen_harness)
    provenance["harnessSHA256"] = sha(frozen_harness)
    frozen_build = work / "retained"; frozen_build.mkdir()
    objects = []
    for index, source in enumerate(inputs):
        destination = frozen_build / f"{index}-{source.name}"; shutil.copyfile(source, destination)
        provenance["retainedObjects"][str(source.relative_to(repo))] = sha(destination)
        objects.append(destination)
    modules = frozen_build / "Modules"; modules.mkdir()
    for name in ("UniApiCore", "UniApiPresentation"):
        module = public_file(build / "Modules" / (name + ".swiftmodule"), repo)
        shutil.copyfile(module, modules / module.name)
        provenance["modules"][str(module.relative_to(repo))] = sha(modules / module.name)
    # Freeze C headers/module maps as well; no private or installed app inputs.
    support = work / "Support"; support.mkdir()
    for name in ("CSQLite", "CNativeSystem", "CZstd"):
        shutil.copytree(native / "Sources" / name, support / name)
    # SwiftPM's generated C map contains absolute original header locations.
    # Freeze that map too, redirecting only its public include directory.
    c_map = public_file(build / "CZstd.build/module.modulemap", repo)
    original_map = c_map.read_text()
    frozen_map = original_map.replace(str(native / "Sources/CZstd/include"), str(support / "CZstd/include"))
    (support / "CZstd/module.modulemap").write_text(frozen_map)
    provenance["cModuleMap"] = {"originalSHA256": sha(c_map),
        "copiedSHA256": sha(support / "CZstd/module.modulemap"),
        "transform": "Redirect public CZstd include directory to its exact copied headers"}
    app = work / "PublicPageCapture.app"
    macos = app / "Contents/MacOS"; macos.mkdir(parents=True)
    resources = app / "Contents/Resources/Helpers"; resources.mkdir(parents=True)
    shutil.copyfile(helper, resources / "uniapi-whisper")
    (resources / "uniapi-whisper").chmod(0o700)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.uniapi.public-page-capture", "CFBundleExecutable": "PublicPageCapture",
        "CFBundleName": "Public page capture", "CFBundlePackageType": "APPL", "LSUIElement": True,
        "CFBundleShortVersionString": info["CFBundleShortVersionString"], "NSHighResolutionCapable": True}))
    binary = macos / "PublicPageCapture"
    command = [str(compiler), "-parse-as-library", "-module-name", "UniApi", "-package-name", package,
        "-swift-version", "5", "-O", "-whole-module-optimization", "-j2", "-num-threads", "2",
        "-target", target, "-sdk", str(sdk), "-I", str(modules), "-I", str(support / "CZstd/include"),
        "-module-cache-path", str(work / "ModuleCache")]
    command += [flag for flag in other if flag.startswith("-D")]
    for name in ("CSQLite", "CNativeSystem"):
        command += ["-Xcc", "-fmodule-map-file=" + str(support / name / "module.modulemap")]
    command += ["-Xcc", "-fmodule-map-file=" + str(support / "CZstd/module.modulemap")]
    command += [str(path) for path in frozen_sources + [frozen_harness] + objects]
    command += ["-o", str(binary)]
    provenance["build"] = {"target": target, "sdk": sdk.name, "packageName": package,
                           "compilerJobs": 2, "backendThreads": 2,
                           "conditionalFlags": [flag for flag in other if flag.startswith("-D")]}
    (work / "composition.json").write_text(json.dumps(provenance, indent=2) + "\n")
    # Build/runtime logs stay private under work/, never in publication images/.
    build_env = {key: os.environ[key] for key in ("PATH", "DEVELOPER_DIR") if key in os.environ}
    build_env["PATH"] = build_env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    build_env["HOME"] = str(work)
    execute(command, build_env, work, work / "compile.log", 900)
    for source in ui_sources:
        if sha(source) != provenance["sources"][str(source.relative_to(repo))]["originalSHA256"]:
            raise ValueError("UI source changed during capture compilation; rebuild and retry")
    # Deny all network and child execution in both fixture and capture modes.
    # AppKit uses the existing window server; no screen recording or input API.
    sandbox = Path("/usr/bin/sandbox-exec")
    if not sandbox.is_file():
        raise ValueError("Required runtime isolation tool unavailable; do not run unsandboxed")
    cases = []
    for page in ("stats", "transcribe", "settings"):
        for appearance in ("light", "dark"):
            case = work / (page + "-" + appearance); case.mkdir()
            # A fresh generic temporary home avoids disclosing operator paths in
            # Settings. Only our schemas/configuration are created within it.
            with tempfile.TemporaryDirectory(prefix="uniapi-public-page-", dir="/tmp") as temporary:
                home = Path(temporary) / "home"; home.mkdir(mode=0o700)
                root = home / "UniApi"
                tmp = home / "tmp"; tmp.mkdir(mode=0o700)
                env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "CFFIXED_USER_HOME": str(home),
                    "TMPDIR": str(tmp) + "/", "UNIAPI_NATIVE_HOME": str(home),
                    "UNIAPI_ROOT": str(root), "UNIAPI_DATA": str(root / "data"),
                    "UNIAPI_PROVIDERS": str(root / "providers.json"), "UNIAPI_NATIVE_READ_ONLY": "1",
                    "CODEX_HOME": str(home / ".codex"), "ZCODE_HOME": str(home / ".zcode"),
                    "XDG_DATA_HOME": str(home / ".local/share"), "DSH_HOME": str(home / ".dsh"),
                    "UNIAPI_NATIVE_UI_METRICS": str(case / "readiness.jsonl")}
                # sandbox-exec must be able to exec the harness itself, but
                # cannot launch any other executable or fork children. Deny
                # operator-home reads even if Foundation ignores HOME while
                # discovering optional executables or default preferences.
                profile = ("(version 1)(allow default)(deny network*)(deny process-fork)"
                    "(deny process-exec)(allow process-exec (literal " + json.dumps(str(binary)) + "))"
                    "(deny file-read* (subpath " + json.dumps(str(Path.home())) + "))"
                    "(allow file-read* (subpath " + json.dumps(str(work)) + "))"
                    "(deny file-write*)(allow file-write* (subpath " + json.dumps(str(work)) + ")"
                    " (subpath " + json.dumps(str(Path(temporary).resolve())) + "))")
                prefix = [str(sandbox), "-p", profile, str(binary)]
                execute(prefix + ["--prepare-fixture", str(root), str(home)], env, home, case / "prepare.log", 30)
                execute(prefix + ["--capture", str(root), str(home), str(case), page, appearance],
                        env, home, case / "capture.log", 30)
            report = json.loads((case / "capture.json").read_text())
            if not report.get("quiet") or not report.get("samples") or not all(row["quiet"] for row in report["samples"]):
                raise ValueError("Quiet capture observations were not established")
            filename = page + "-" + appearance + ".png"
            shutil.copyfile(case / "page.png", images / filename)
            cases.append({"page": page, "appearance": appearance, "image": filename, "label": LABEL,
                          "sha256": sha(images / filename), "viewport": [1050, 800]})
    for page in ("stats", "transcribe", "settings"):
        if sha(images / (page + "-light.png")) == sha(images / (page + "-dark.png")):
            raise ValueError("Light and Dark captures unexpectedly match")
    (images / "manifest.json").write_text(json.dumps({"kind": "offscreen-native-page-empty-fixture",
        "label": LABEL, "requiresVisualReview": True, "completeShell": False,
        "compositorCapture": False, "freshInstalledAcceptance": False, "cases": cases}, indent=2) + "\n")
    print("Six native page bitmaps prepared. Visually inspect images/ before publication.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit("Capture failed; no screenshot set accepted: " + str(error))
