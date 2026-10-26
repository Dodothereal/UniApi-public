#!/usr/bin/env python3
"""Build/run the private bitmap proof; never launch the production application."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(command, timeout, log):
    # swiftc can own frontend/linker children. The timeout owns the entire
    # newly created group, never a shared application/service process group.
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate(timeout=5)
        log.write_bytes(stdout + stderr)
        raise
    log.write_bytes(stdout + stderr)
    return process.returncode, stdout


def main():
    source = Path(__file__).resolve().with_name("Proof.swift")
    repo = source.parents[4]
    cache = repo / ".cache"
    cache.mkdir(exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="native-ui-capture-proof-", dir=cache))
    root.chmod(0o700)
    output = root / "captures"
    output.mkdir(mode=0o700)
    frozen = root / "Proof.swift"
    frozen.write_bytes(source.read_bytes())
    source_hash = sha(frozen)
    binary = root / "NativeCaptureProof"
    toolchain = Path("/Library/Developer/CommandLineTools/usr/bin")
    sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
    command = [str(toolchain / "swiftc"), "-parse-as-library", "-swift-version", "5",
               "-O", "-whole-module-optimization", "-j2", "-num-threads", "2",
               "-target", "arm64-apple-macosx14.0", "-sdk", str(sdk),
               "-module-cache-path", str(root / "ModuleCache"),
               "-Xlinker", "-platform_version", "-Xlinker", "macos",
               "-Xlinker", "14.0", "-Xlinker", "26.5", str(frozen), "-o", str(binary)]
    receipt = {"sourceSHA256": source_hash, "command": command, "productionAppLaunched": False}
    try:
        started = time.monotonic()
        code, _ = execute(command, timeout=90, log=root / "compile.log")
        receipt.update(compileExit=code, compileSeconds=time.monotonic() - started)
        if code:
            raise RuntimeError("Capture proof compilation failed; see compile.log")
        code, header = execute([str(toolchain / "vtool"), "-show-build", str(binary)],
                               timeout=5, log=root / "vtool.log")
        if code:
            raise RuntimeError("Executable header inspection failed")
        fields = dict(line.split(None, 1) for line in header.decode().splitlines()
                      if len(line.split(None, 1)) == 2)
        fields = {key.strip(): value.strip() for key, value in fields.items()}
        if any(fields.get(key) != value for key, value in
               [("platform", "MACOS"), ("minos", "14.0"), ("sdk", "26.5")]):
            raise RuntimeError("Unexpected executable SDK/platform header")
        if sha(frozen) != source_hash:
            raise RuntimeError("Frozen source changed")
        receipt["binarySHA256"] = sha(binary)
        started = time.monotonic()
        code, _ = execute([str(binary), str(output)], timeout=10, log=root / "runtime.log")
        receipt.update(runtimeExit=code, runtimeSeconds=time.monotonic() - started)
        report = json.loads((output / "report.json").read_text())
        if code or not report.get("quiet") or len(report.get("samples", [])) != 5:
            raise RuntimeError("Capture proof did not establish its quiet bitmap case")
        if not all(sample.get("quiet") for sample in report["samples"]):
            raise RuntimeError("Capture proof has a non-quiet observation")
        if (output / "dark.png").read_bytes() == (output / "light.png").read_bytes():
            raise RuntimeError("Light and Dark output did not differ")
        receipt["artifacts"] = {p.name: sha(p) for p in sorted(output.iterdir()) if p.is_file()}
        receipt["passed"] = True
    except Exception as error:
        receipt.update(passed=False, error=str(error))
    (root / "execution.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"passed": receipt["passed"], "root": str(root),
                      "captures": str(output), "error": receipt.get("error")}, indent=2))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
