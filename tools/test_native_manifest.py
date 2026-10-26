"""Native artifact fixtures: no app/helper execution or real compiler commands."""
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
spec = importlib.util.spec_from_file_location("native_manifest", TOOLS / "native_manifest.py")
manifest = importlib.util.module_from_spec(spec); spec.loader.exec_module(manifest)
spec = importlib.util.spec_from_file_location("native_release_manifest_fixture", TOOLS / "package_release.py")
package = importlib.util.module_from_spec(spec); spec.loader.exec_module(package)
MACHO = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)


def native_fixture(root):
    """Complete manifest fixture, reusable by the parent-owned package tests."""
    root = Path(root); repo = root / "repo"; binaries = root / "binaries"
    binaries.mkdir(parents=True)
    for name in ("UniApiNative", "uniapi-battery", "uniapi-shim", "uniapi-fans", "uniapi-whisper"):
        (binaries / name).write_bytes(MACHO); (binaries / name).chmod(0o755)
    for relative in manifest.APP_RESOURCES.values():
        file = repo / relative; file.parent.mkdir(parents=True, exist_ok=True)
        if file.suffix == ".sh": data = b"#!/bin/bash\n# fixture installer; never executed\nexit 0\n"
        elif file.suffix == ".icns": data = b"icns" + struct.pack(">I", 8)
        elif file.suffix == ".json": data = b'{"providers":[]}'
        else: data = b"Fixture license text\n"
        file.write_bytes(data)
    stage = root / "stage"; stage.mkdir()
    manifest.stage_app(repo, binaries, binaries / "uniapi-fans", stage / "UniApi.app", "production", "3.0.0", whisper_helper=binaries / "uniapi-whisper")
    for relative in manifest.PACKAGE_FILES:
        file = stage / relative; file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text("#!/bin/bash\nexit 0\n" if relative.endswith(".sh") else "Fixture installation/license text\n")
    return repo, binaries, stage


@unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "Native macOS descriptor fixtures require POSIX")
class NativeManifestTests(unittest.TestCase):
    def test_complete_manifest_preserves_every_resource_and_optional_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo, _, stage = native_fixture(temporary)
            package.assert_native_stage(stage, version="3.0.0")
            for relative, source in manifest.APP_RESOURCES.items():
                self.assertEqual((stage / "UniApi.app" / relative).read_bytes(), (repo / source).read_bytes())
            seal = stage / "UniApi.app" / manifest.SIGNATURE_FILE
            seal.parent.mkdir(); seal.write_bytes(plistlib.dumps({"files2": {}}))
            package.assert_native_stage(stage)

    def test_whisper_is_required_native_executable_and_license_is_exactly_staged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); repo, binaries, stage = native_fixture(root)
            self.assertEqual(len(manifest.APP_EXECUTABLES), 5)
            helper = stage / "UniApi.app/Contents/Resources/Helpers/uniapi-whisper"
            license = stage / "UniApi.app/Contents/Resources/Licenses/Whisper-LICENSE"
            self.assertEqual(helper.read_bytes(), MACHO)
            self.assertEqual(license.read_bytes(), (repo / "native/swift/Resources/Whisper-LICENSE.txt").read_bytes())
            for data in (b"#!/bin/bash\nexit 0\n", b"SQLite format 3\0"):
                helper.write_bytes(data)
                with self.assertRaises(RuntimeError): package.assert_native_stage(stage)
            helper.unlink()
            with self.assertRaises(RuntimeError): package.assert_native_stage(stage)
            helper.write_bytes(MACHO); helper.chmod(0o755)
            license_data = license.read_bytes(); license.unlink()
            with self.assertRaises(RuntimeError): package.assert_native_stage(stage)
            license.write_bytes(license_data)
            source = binaries / "uniapi-whisper"
            source.unlink(); source.symlink_to(binaries / "uniapi-shim")
            target = root / "next.app"
            with self.assertRaises(RuntimeError):
                manifest.stage_app(repo, binaries, binaries / "uniapi-fans", target, "production", "3.0.0", whisper_helper=source)
            self.assertFalse(target.exists())

    def test_mjs_sqlite_unknown_helpers_scripts_and_directories_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, _, stage = native_fixture(temporary)
            for relative in ("UniApi.app/Contents/Resources/Licenses/runtime.mjs",
                             "UniApi.app/Contents/Resources/Licenses/private-store.sqlite",
                             "UniApi.app/Contents/Resources/Helpers/unexpected",
                             "tools/extra.sh", "UniApi.app/Contents/Resources/.env"):
                with self.subTest(relative=relative):
                    file = stage / relative; file.write_text("fixture runtime/operator data")
                    with self.assertRaises(RuntimeError): package.assert_native_stage(stage)
                    file.unlink()
            directory = stage / "UniApi.app/Contents/Resources/private-data"; directory.mkdir()
            with self.assertRaises(RuntimeError): package.assert_native_stage(stage)
            directory.rmdir(); package.assert_native_stage(stage)

    def test_linked_file_directory_and_hardlink_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); _, _, stage = native_fixture(root)
            resource = stage / "UniApi.app/Contents/Resources/Licenses/UniApi-LICENSE"
            bytes_before = resource.read_bytes(); outside = root / "private-store.sqlite"; outside.write_bytes(bytes_before)
            resource.unlink(); resource.symlink_to(outside)
            with self.assertRaises(RuntimeError): package.assert_native_stage(stage)
            resource.unlink(); os.link(outside, resource)
            with self.assertRaises(RuntimeError): package.assert_native_stage(stage)
            resource.unlink(); resource.write_bytes(bytes_before)
            directory = stage / "tools"; directory.rename(root / "linked-tools"); directory.symlink_to(root / "linked-tools", target_is_directory=True)
            with self.assertRaises(RuntimeError): package.assert_native_stage(stage)
            self.assertEqual(outside.read_bytes(), bytes_before)

    def test_missing_resource_and_renamed_runtime_in_executable_slot_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, _, stage = native_fixture(temporary)
            icon = stage / "UniApi.app/Contents/Resources/UniApi.icns"; icon.unlink()
            with self.assertRaises(RuntimeError): package.assert_native_stage(stage)
        for data in (b"#!/bin/bash\nnode runtime.mjs\n", b"SQLite format 3\0", MACHO[:8]):
            with self.subTest(data=data), tempfile.TemporaryDirectory() as temporary:
                _, _, stage = native_fixture(temporary)
                (stage / "UniApi.app/Contents/Resources/Helpers/uniapi-shim").write_bytes(data)
                with self.assertRaises(RuntimeError): package.assert_native_stage(stage)

    def test_production_identity_version_and_preview_flags_are_exact(self):
        changes = [{"CFBundleIdentifier": "app.devved.uniapi.native-development"}, {"CFBundleExecutable": "node"},
                   {"CFBundleShortVersionString": "4.0.0"}, {"UniApiReadOnlyPreview": False},
                   {"UniApiUIProfileOutput": "/private/tmp/fixture"}, {"UniApiUIProfilePage": "stats"},
                   {"LSMinimumSystemVersion": "15.0"}, {"NSHighResolutionCapable": 1}]
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                _, _, stage = native_fixture(temporary); file = stage / "UniApi.app/Contents/Info.plist"
                info = plistlib.loads(file.read_bytes()); info.update(change); file.write_bytes(plistlib.dumps(info))
                with self.assertRaises(RuntimeError): package.assert_native_stage(stage, version="3.0.0")

    def test_source_resource_extras_links_and_missing_license_fail_before_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); repo, binaries, _ = native_fixture(root)
            resources = repo / "native/fans/Resources"; target = root / "next.app"
            for name in ("runtime.mjs", "private-store.sqlite"):
                extra = resources / name; extra.write_text("fixture")
                with self.assertRaises(RuntimeError): manifest.stage_app(repo, binaries, binaries / "uniapi-fans", target, "production", "3.0.0", whisper_helper=binaries / "uniapi-whisper")
                self.assertFalse(target.exists()); extra.unlink()
            source = resources / manifest.FAN_LICENSES[0]; original = source.read_bytes()
            source.unlink(); source.symlink_to(repo / "LICENSE")
            with self.assertRaises(RuntimeError): manifest.stage_app(repo, binaries, binaries / "uniapi-fans", target, "production", "3.0.0", whisper_helper=binaries / "uniapi-whisper")
            source.unlink(); source.write_bytes(original); (repo / "LICENSE").unlink()
            with self.assertRaisesRegex(RuntimeError, "missing or linked"):
                manifest.stage_app(repo, binaries, binaries / "uniapi-fans", target, "production", "3.0.0", whisper_helper=binaries / "uniapi-whisper")
            self.assertFalse(target.exists())

    def test_source_ancestor_links_fail_before_any_staged_output(self):
        for relative in ("assets", "native/fans", "native/swift/tools", "native"):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); repo, binaries, _ = native_fixture(root)
                ancestor = repo / relative; outside = root / "external-resources"
                ancestor.rename(outside); ancestor.symlink_to(outside, target_is_directory=True)
                target = root / "next.app"
                with self.assertRaises(RuntimeError): manifest.validate_inputs(repo)
                with self.assertRaises(RuntimeError):
                    manifest.stage_app(repo, binaries, binaries / "uniapi-fans", target, "production", "3.0.0", whisper_helper=binaries / "uniapi-whisper")
                self.assertFalse(target.exists())

    def test_selected_root_aliases_are_allowed_but_relative_escape_is_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); repo, binaries, _ = native_fixture(root)
            repo_alias, binary_alias = root / "selected-repo", root / "selected-binaries"
            repo_alias.symlink_to(repo, target_is_directory=True); binary_alias.symlink_to(binaries, target_is_directory=True)
            output = root / "output"; output.mkdir()
            output_alias = root / "selected-output"; output_alias.symlink_to(output, target_is_directory=True)
            app = output_alias / "next.app"
            manifest.validate_inputs(repo_alias)
            manifest.stage_app(repo_alias, binary_alias, binary_alias / "uniapi-fans", app, "production", "3.0.0", whisper_helper=binary_alias / "uniapi-whisper")
            manifest.validate_app(app, "production", "3.0.0")
            for relative, source in manifest.APP_RESOURCES.items():
                self.assertEqual((app / relative).read_bytes(), (repo / source).read_bytes())
            with manifest.ManifestDirectory(repo_alias) as admitted:
                for path in ("../binaries/uniapi-shim", str(binaries / "uniapi-shim")):
                    with self.subTest(path=path), self.assertRaises(RuntimeError): admitted.read(path)

    def test_resource_copy_uses_pinned_directory_and_file_descriptors_after_replacement(self):
        for boundary in ("directory", "file"):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); repo, binaries, _ = native_fixture(root)
                source = repo / "assets/UniApi.icns"; original = source.read_bytes()
                source_inode = source.stat().st_ino
                outside = root / "outside-assets"; outside.mkdir()
                foreign = b"icns" + struct.pack(">I", 12) + b"fake"
                (outside / source.name).write_bytes(foreign)
                opened, read = os.open, os.read
                swapped = False
                def replace_parent():
                    nonlocal swapped
                    swapped = True
                    source.parent.rename(root / "admitted-assets")
                    source.parent.symlink_to(outside, target_is_directory=True)
                def open_at(file, flags, mode=0o777, *, dir_fd=None):
                    if boundary == "directory" and not swapped and file == source.name and dir_fd is not None:
                        replace_parent()
                    return opened(file, flags, mode, dir_fd=dir_fd)
                def read_at(fd, count):
                    if boundary == "file" and not swapped and os.fstat(fd).st_ino == source_inode:
                        replace_parent()
                    return read(fd, count)
                app = root / "next.app"
                with mock.patch.object(manifest.os, "open", side_effect=open_at), mock.patch.object(manifest.os, "read", side_effect=read_at):
                    manifest.stage_app(repo, binaries, binaries / "uniapi-fans", app, "production", "3.0.0", whisper_helper=binaries / "uniapi-whisper")
                self.assertTrue(swapped)
                self.assertEqual((app / "Contents/Resources/UniApi.icns").read_bytes(), original)
                self.assertEqual((outside / source.name).read_bytes(), foreign)
                with self.assertRaises(RuntimeError): manifest.validate_inputs(repo)


class NativeArchiveHashTests(unittest.TestCase):
    def test_sha256_uses_bounded_incremental_reads_without_python311_api(self):
        payload = bytes(range(256)) * 9000
        class BoundedStream(io.BytesIO):
            def read(self, size=-1):
                if not 0 < size <= 1 << 20:
                    raise AssertionError("Archive hashing must use bounded reads")
                return super().read(size)
        with mock.patch.object(package.hashlib, "file_digest", create=True, side_effect=AssertionError("Python 3.11 API must not be used")):
            self.assertEqual(package.sha256_stream(BoundedStream(payload)), hashlib.sha256(payload).hexdigest())
            self.assertEqual(package.sha256_stream(BoundedStream()), hashlib.sha256(b"").hexdigest())


@unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "Native build fixtures require POSIX")
class NativeBuildDiscoveryTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory); repo, binaries, _ = native_fixture(root)
        swift = repo / "native/swift"; (swift / "Sources").mkdir(exist_ok=True); (swift / "Tests").mkdir()
        (swift / "Sources/generation").write_text("first"); (swift / "Package.swift").write_text("fixture package")
        (repo / "native/fans/Core").mkdir(); (repo / "native/fans/Core/fixture.swift").write_text("fixture")
        (repo / "native/fans/main.swift").write_text("fixture")
        for relative in ("native/swift/build.sh", "native/swift/tools/build-snapshot.sh", "native/swift/tools/swift-environment.sh", "native/swift/tools/verify-ci.sh", "tools/native_manifest.py", "tools/generate_statistics_pricing.py", "resources/pricing-catalog.json", "native/swift/Sources/UniApiCore/StatisticsPriceCatalog.swift"):
            target = repo / relative; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(ROOT / relative, target)
        # Build plumbing fixture: never run CMake, download sources or execute ASR.
        (repo / "tools/build-local-whisper.sh").write_text('#!/bin/bash\nset -euo pipefail\n[[ $# == 2 && "$1" == --output ]]\ncp "$UNIAPI_MANIFEST_FIXTURE/binaries/uniapi-whisper" "$2"\n')
        (repo / "native/swift/tools/verify.sh").write_text('#!/bin/bash\nprintf "%s\\n%s\\n" "$UNIAPI_SWIFT_SDK" "$UNIAPI_SWIFT_TOOLCHAIN"\n')
        (repo / "native/swift/tools/install-native.sh").write_text("#!/bin/bash\n# fixture only; never executed\nexit 0\n")
        developer = root / "Xcode Fixture.app/Contents/Developer"
        sdk = developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"; sdk.mkdir(parents=True)
        commands = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin"; commands.mkdir(parents=True)
        compiler = commands / "swift"
        compiler.write_text('''#!/usr/bin/env python3
import json, os, pathlib, struct, sys, time
a=sys.argv[1:]; root=pathlib.Path(os.environ['UNIAPI_MANIFEST_FIXTURE']); cwd=pathlib.Path.cwd()
with (root/'calls').open('a') as f: f.write(json.dumps({'args':a,'sdk':os.environ.get('SDKROOT'),'clang':os.environ.get('CLANG_MODULE_CACHE_PATH'),'modules':os.environ.get('SWIFTPM_MODULECACHE_OVERRIDE')})+'\\n')
if pathlib.Path(sys.argv[0]).name=='swiftc':
 out=pathlib.Path(a[a.index('-o')+1]); out.write_bytes(struct.pack('<IIIIIIII',0xFEEDFACF,0x0100000C,0,2,0,0,0,0)); sys.exit(0)
pkg=pathlib.Path(a[a.index('--package-path')+1]) if '--package-path' in a else cwd
scratch=pathlib.Path(a[a.index('--scratch-path')+1]) if '--scratch-path' in a else cwd/'.build/fixture'
bin=scratch/'bin'; bin.mkdir(parents=True,exist_ok=True)
if '--show-bin-path' in a: print(bin); sys.exit(0)
assert a[a.index('-j')+1]=='2'
if os.environ.get('UNIAPI_MANIFEST_RACE')=='1':
 generation=(pkg/'Sources/generation').read_text()
 if generation=='first':
  (root/'first-started').touch()
  for _ in range(500):
   if (root/'second-finished').exists(): break
   time.sleep(.01)
  (root/'first-observed').write_text((pkg/'Sources/generation').read_text())
 else: (root/'second-finished').touch()
for n in ('UniApiNative','uniapi-battery','uniapi-shim'):
 file=bin/n; file.write_bytes(struct.pack('<IIIIIIII',0xFEEDFACF,0x0100000C,0,2,0,0,0,0)); file.chmod(0o755)
print('fixture compiler progress')
''')
        compiler.chmod(0o755); shutil.copy2(compiler, commands / "swiftc")
        for name, content in {"uname": "#!/bin/bash\n[[ \"${1:-}\" != -s ]] || { echo Darwin; exit; }; echo arm64\n",
                              "vtool": "#!/bin/bash\necho 'minos 14.0'\n", "plutil": "#!/bin/bash\nexit 0\n",
                              "codesign": "#!/bin/bash\nexit 0\n",
                              "strip": "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$UNIAPI_MANIFEST_FIXTURE/strip-calls\"\n[[ \"${UNIAPI_MANIFEST_STRIP_FAIL:-0}\" != 1 ]] || exit 9\n"}.items():
            file = commands / name; file.write_text(content); file.chmod(0o755)
        env = os.environ.copy()
        for name in ("UNIAPI_SWIFT_SDK", "UNIAPI_SWIFT_TOOLCHAIN", "UNIAPI_NATIVE_BUILD_ROOT", "UNIAPI_NATIVE_VERSION", "UNIAPI_NATIVE_BUNDLE_VARIANT", "UNIAPI_NATIVE_CONFIGURATION"):
            env.pop(name, None)
        env.update(DEVELOPER_DIR=str(developer), PATH=str(commands) + os.pathsep + env["PATH"], UNIAPI_MANIFEST_FIXTURE=str(root))
        return repo, sdk, compiler, env

    def test_developer_sdk_and_explicit_overrides_choose_the_same_toolchain(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo, sdk, compiler, env = self.fixture(temporary)
            for relative in ("native/swift/tools/swift-environment.sh", "native/swift/tools/verify-ci.sh"):
                result = subprocess.run(["bash", str(repo / relative)], env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr); self.assertEqual(result.stdout.splitlines(), [str(sdk), str(compiler)])
            env.update(UNIAPI_SWIFT_SDK=str(sdk), UNIAPI_SWIFT_TOOLCHAIN=str(compiler))
            result = subprocess.run(["bash", str(repo / "native/swift/tools/swift-environment.sh")], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.stdout.splitlines(), [str(sdk), str(compiler)])
            self.assertFalse((Path(temporary) / "calls").exists())

    def test_unavailable_or_wrong_sdk_and_missing_compiler_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo, _, compiler, env = self.fixture(temporary)
            for name in ("MacOSX26.5.sdk", "MacOSX27.0.sdk"):
                env["UNIAPI_SWIFT_SDK"] = str(Path(temporary) / name)
                if name.endswith("27.0.sdk"): Path(env["UNIAPI_SWIFT_SDK"]).mkdir()
                result = subprocess.run(["bash", str(repo / "native/swift/tools/swift-environment.sh")], env=env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
            env.pop("UNIAPI_SWIFT_SDK"); compiler.unlink()
            result = subprocess.run(["bash", str(repo / "native/swift/tools/swift-environment.sh")], env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)

    def test_parallel_fake_compilers_keep_distinct_frozen_source_and_bin_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); repo, sdk, _, env = self.fixture(root); env["UNIAPI_MANIFEST_RACE"] = "1"
            command = ["bash", str(repo / "native/swift/tools/build-snapshot.sh")]
            first = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                for _ in range(500):
                    if (root / "first-started").exists(): break
                    time.sleep(.01)
                self.assertTrue((root / "first-started").exists())
                (repo / "native/swift/Sources/generation").write_text("second")
                second = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
                first_out, first_error = first.communicate(timeout=10)
                self.assertEqual(first.returncode, 0, first_error); self.assertEqual(second.returncode, 0, second.stderr)
                self.assertEqual((root / "first-observed").read_text(), "first")
                self.assertNotEqual(first_out.strip(), second.stdout.strip())
                for output in (first_out, second.stdout): self.assertTrue((Path(output.strip()) / "UniApiNative").is_file())
                calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
                self.assertTrue(all(call["sdk"] == str(sdk) for call in calls))
                self.assertEqual(len({call["clang"] for call in calls}), 2)
                packages = {call["args"][call["args"].index("--package-path") + 1] for call in calls}
                scratch = {call["args"][call["args"].index("--scratch-path") + 1] for call in calls}
                self.assertEqual(len(packages), 2); self.assertEqual(len(scratch), 2)
                self.assertEqual(scratch, {str(Path(path) / "build") for path in packages})
            finally:
                if first.poll() is None: first.kill(); first.wait()

    def test_build_and_package_use_exact_resources_and_shared_discovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); repo, sdk, compiler, env = self.fixture(root)
            with mock.patch.object(package, "ROOT", str(repo)), mock.patch.object(package, "DIST", str(root / "dist")), mock.patch.dict(os.environ, env, clear=True):
                self.assertEqual(package.package_native_macos("3.0.0"), 0)
            stage = root / "dist/UniApi-macos-3.0.0"; package.assert_native_stage(stage, version="3.0.0")
            self.assertTrue((root / "dist/UniApi-macos-3.0.0.zip").is_file())
            self.assertFalse(list((root / "dist").glob(".native-build-*")))
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
            self.assertTrue(all(call["sdk"] == str(sdk) for call in calls))
            self.assertFalse((repo / "native/swift/build.noindex/UniApi.app").exists())
            stripped = (root / "strip-calls").read_text().splitlines()
            self.assertEqual(len(stripped), 5)
            self.assertTrue(all(line.startswith("-S -x ") for line in stripped))
            self.assertEqual({Path(line[6:]).name for line in stripped}, {"UniApiNative", "uniapi-battery", "uniapi-shim", "uniapi-fans", "uniapi-whisper"})

    def test_failed_release_strip_preserves_previous_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); repo, _, _, env = self.fixture(root)
            previous = repo / "native/swift/build.noindex/UniApi.app"
            previous.mkdir(parents=True); (previous / "previous").write_text("preserved")
            env.update(UNIAPI_NATIVE_BUNDLE_VARIANT="production", UNIAPI_MANIFEST_STRIP_FAIL="1")
            result = subprocess.run(["bash", str(repo / "native/swift/build.sh")], env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((previous / "previous").read_text(), "preserved")
            self.assertEqual(len((root / "strip-calls").read_text().splitlines()), 1)

    def test_stale_pricing_catalog_refuses_before_any_compiler_call(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); repo, _, _, env = self.fixture(root)
            output = repo / "native/swift/Sources/UniApiCore/StatisticsPriceCatalog.swift"
            output.write_text("// stale generated data")
            for relative in ("native/swift/build.sh", "native/swift/tools/build-snapshot.sh"):
                result = subprocess.run(["bash", str(repo / relative)], env=env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0); self.assertIn("stale", result.stderr)
                self.assertFalse((root / "calls").exists())
            self.assertEqual(output.read_text(), "// stale generated data")

    def test_resource_preflight_refuses_extras_missing_inputs_and_output_links_before_compiling(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); repo, _, _, env = self.fixture(root)
            command = ["bash", str(repo / "native/swift/build.sh")]
            extra = repo / "native/fans/Resources/runtime.mjs"; extra.write_text("fixture")
            refused = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(refused.returncode, 0); self.assertFalse((root / "calls").exists()); extra.unlink()
            license = repo / "LICENSE"; content = license.read_bytes(); license.unlink()
            refused = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(refused.returncode, 0); self.assertFalse((root / "calls").exists()); license.write_bytes(content)
            helpers = repo / "native/swift/build.noindex/Helpers"; helpers.mkdir(parents=True)
            outside = root / "unrelated-helper"; outside.write_text("preserved")
            (helpers / "uniapi-battery").symlink_to(outside)
            refused = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(refused.returncode, 0); self.assertFalse((root / "calls").exists())
            self.assertEqual(outside.read_text(), "preserved")


if __name__ == "__main__":
    unittest.main(verbosity=2)
