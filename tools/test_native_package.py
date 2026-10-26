"""Packaging/installer probes use fake apps, commands and private temp trees."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "tools/package_release.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
spec = importlib.util.spec_from_file_location("native_manifest_fixtures", ROOT / "tools/test_native_manifest.py")
manifest_fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest_fixtures)


# These adapters exercise the actual installer script without invoking launchd,
# signing tools or an installed application. Parse real JSON/plists so incorrect
# field names, stdin handling and preservation of unrelated keys cannot pass by
# way of a command that always returns a success-shaped answer.
FIXTURE_PLUTIL = r'''
import json, os, plistlib, sys
from pathlib import Path
args = sys.argv[1:]
try:
    path = args[-1]
    raw = sys.stdin.buffer.read() if path == "-" else Path(path).read_bytes()
    try: value = plistlib.loads(raw)
    except Exception:
        try: value = json.loads(raw)
        except Exception:
            if not raw.startswith(b"old "): raise
            value = {}
            if os.environ.get("UNIAPI_FIXTURE_OLD_ROOT"):
                value["EnvironmentVariables"] = {"UNIAPI_ROOT": os.environ["UNIAPI_FIXTURE_OLD_ROOT"]}
            if path.endswith("app.devved.uniapi-server.plist") and os.environ.get("FIXTURE_WORKING_DIRECTORY"):
                value["WorkingDirectory"] = os.environ["FIXTURE_WORKING_DIRECTORY"]
    if args[0] == "-extract":
        for key in args[1].split("."): value = value[key]
        if isinstance(value, bool): print("true" if value else "false")
        elif isinstance(value, (str, int, float)): print(value)
        else: raise ValueError("raw extraction requires a scalar")
    elif args[0] == "-convert":
        Path(args[args.index("-o") + 1]).write_bytes(plistlib.dumps(value))
    elif args[0] == "-replace":
        keys = args[1].split(".")
        target = value
        for key in keys[:-1]: target = target[key]
        if keys[-1] not in target: raise KeyError(keys[-1])
        target[keys[-1]] = args[args.index("-string") + 1]
        Path(path).write_bytes(plistlib.dumps(value))
    elif args[0] != "-lint": raise ValueError("unsupported plutil operation")
except Exception as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
'''

FIXTURE_NATIVE = r'''
import hashlib, json, os, sys
from pathlib import Path
args = sys.argv[1:]
def flag(name): return os.environ.get("UNIAPI_FIXTURE_" + name) == "1"
def log(message):
    with open(os.environ["UNIAPI_FIXTURE_LOG"], "a") as output: output.write(message + "\n")
def emit(value, code=0):
    print(json.dumps(value))
    sys.exit(code)
labels = ("app.devved.uniapi-server", "app.devved.uniapi-shim")
agents = Path(os.environ["UNIAPI_NATIVE_LAUNCH_AGENTS"])
old_nonce = os.environ.get("UNIAPI_FIXTURE_OLD_NONCE", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
operation = args[0]
if operation == "--prepare-install":
    if flag("BUSY"): emit({"status": "refused", "safeToInstall": False}, 2)
    kind = "native" if flag("NATIVE") else "legacy"
    if os.environ.get("UNIAPI_FIXTURE_SECOND_PLAN_CHANGE"):
        count = Path(os.environ["UNIAPI_FIXTURE_LOG"]).parent / "prepare-count"
        index = int(count.read_text()) + 1 if count.exists() else 1
        count.write_text(str(index))
        if index == 2:
            change = os.environ["UNIAPI_FIXTURE_SECOND_PLAN_CHANGE"]
            if change == "definition": (agents / (labels[0] + ".plist")).write_text("operator replacement")
            elif change == "app": (Path(args[1]) / "old-app").write_text("operator app replacement")
            elif change == "kind": kind = "legacy"
            elif change == "nonce": old_nonce = "11111111-2222-3333-4444-555555555555"
    result = {"status": "prepared", "kind": kind, "canPrepare": True, "safeToInstall": False}
    if kind == "native":
        result.update(oldInstance=old_nonce, definitionHashes={label: hashlib.sha256((agents / (label + ".plist")).read_bytes()).hexdigest() for label in labels})
    emit(result)
elif operation in ("--prepare-transfer", "--check-transfer"):
    sys.exit(2 if flag("BUSY") else 0)
elif operation in ("--retire-legacy", "--retire-native-update"):
    if operation == "--retire-native-update":
        assert len(args) == 4 and args[1] == old_nonce
        plan = json.loads(args[3])
        assert plan["kind"] == "native" and plan["oldInstance"] == old_nonce
        assert plan["definitionHashes"] == {label: hashlib.sha256((agents / (label + ".plist")).read_bytes()).hexdigest() for label in labels}
    else: assert not flag("NATIVE"), "native update must not use the legacy transaction"
    log(operation[2:])
    if flag("RETIRE_REFUSE"): emit({"status": "refused", "safeToInstall": False}, 2)
    emit({"status": "retired", "safeToInstall": True})
elif operation == "--retire-native-install":
    log("retire-native-install")
    if flag("FOREIGN_NATIVE"): emit({"safeToRestore": False}, 2)
    if flag("OPERATOR_DEFINITION"): (agents / (labels[0] + ".plist")).write_text("operator definition")
    emit({"safeToRestore": True})
elif operation == "--legacy-health":
    assert not flag("NATIVE"), "native rollback must verify its old nonce, not legacy HTTP"
    sys.exit(1 if flag("FAIL_RESTORE") else 0)
elif operation in ("--native-health", "--native-shim-health"):
    restoring = flag("NATIVE") and args[-1] == old_nonce
    if restoring:
        log("restored-native-health " + args[-1])
        sys.exit(1 if flag("FAIL_RESTORE") else 0)
    failed = "FAIL_HEALTH" if operation == "--native-health" else "FAIL_SHIM"
    sys.exit(1 if flag(failed) else 0)
else: sys.exit(1)
'''


@unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "Native installer fixtures require a POSIX filesystem")
class NativePackageTests(unittest.TestCase):
    def test_native_allowlist_rejects_runtime_data_scripts_and_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, _, stage = manifest_fixtures.native_fixture(temporary)
            package.assert_native_stage(stage)
            bad = stage / "UniApi.app" / "providers.json"
            bad.write_text("{}")
            with self.assertRaises(RuntimeError):
                package.assert_native_stage(stage)
            bad.unlink()
            bad = stage / "UniApi.app" / "runtime.js"
            bad.write_text("fixture")
            with self.assertRaises(RuntimeError):
                package.assert_native_stage(stage)
            bad.unlink()
            bad.symlink_to(stage / "LICENSE")
            with self.assertRaises(RuntimeError):
                package.assert_native_stage(stage)

    def fixture(self, temporary):
        directory = Path(temporary)
        commands = directory / "commands"
        commands.mkdir()
        source = directory / "source.app"
        (source / "Contents/MacOS").mkdir(parents=True)
        (source / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "app.devved.uniapi.hub"}))
        executable = source / "Contents/MacOS/UniApiNative"
        executable.write_text("#!" + sys.executable + "\n" + FIXTURE_NATIVE)
        executable.chmod(0o755)
        applications = directory / "Applications"
        applications.mkdir()
        old = applications / "UniApi.app"
        old.mkdir()
        (old / "old-app").write_text("retained")
        agents = directory / "LaunchAgents"
        agents.mkdir()
        for label in ("app.devved.uniapi-server", "app.devved.uniapi-shim"):
            (agents / (label + ".plist")).write_text("old " + label)
        scripts = {
            "plutil": "#!" + sys.executable + "\n" + FIXTURE_PLUTIL,
            "codesign": "#!/bin/bash\nexit 0\n",
            "sleep": "#!/bin/bash\nexit 0\n",
            "uuidgen": '#!/bin/bash\nprintf "%s\\n" "${UNIAPI_FIXTURE_NEW_NONCE:-01234567-89AB-CDEF-0123-456789ABCDEF}"\n',
            "launchctl": '#!/bin/bash\nprintf "%s\\n" "$*" >> "$UNIAPI_FIXTURE_LOG"\nif [[ "$1" == print ]]; then echo "pid = 123"; fi\n',
        }
        for name, content in scripts.items():
            file = commands / name
            file.write_text(content)
            file.chmod(0o755)
        environment = os.environ.copy()
        for key in ("UNIAPI_DATA", "UNIAPI_PROVIDERS", "CODEX_HOME", "ZCODE_HOME", "XDG_DATA_HOME"):
            environment.pop(key, None)
        environment.update(PATH=str(commands) + os.pathsep + "/usr/bin:/bin", UNIAPI_NATIVE_APP_SOURCE=str(source), UNIAPI_ROOT=str(directory / "state"), UNIAPI_NATIVE_APPLICATIONS=str(applications), UNIAPI_NATIVE_LAUNCH_AGENTS=str(agents), UNIAPI_FIXTURE_LOG=str(directory / "calls"))
        return directory, environment

    def native_installation(self, directory, environment):
        environment["UNIAPI_FIXTURE_NATIVE"] = "1"
        old_nonce = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        environment["UNIAPI_FIXTURE_OLD_NONCE"] = old_nonce
        definitions = {}
        for label, executable, argument in (
            ("app.devved.uniapi-server", "Contents/MacOS/UniApiNative", "--background"),
            ("app.devved.uniapi-shim", "Contents/Resources/Helpers/uniapi-shim", "--serve"),
        ):
            value = {
                "Label": label,
                "ProgramArguments": [str(directory / "Applications/UniApi.app" / executable), argument],
                "WorkingDirectory": environment["UNIAPI_ROOT"],
                "EnvironmentVariables": {
                    "UNIAPI_ROOT": environment["UNIAPI_ROOT"],
                    "UNIAPI_NATIVE_INSTALL_NONCE": old_nonce,
                    "CUSTOM_UNRELATED_SETTING": "retain <and> & preserve",
                    "PATH": "/fixture/private/bin:/usr/bin:/bin",
                },
                "KeepAlive": True,
                "RunAtLoad": True,
                "ExitTimeOut": 7,
                "ThrottleInterval": 17,
                "UnrelatedNestedSetting": {"array": [3, False, "same bytes after rollback"]},
            }
            path = directory / "LaunchAgents" / (label + ".plist")
            path.write_bytes(plistlib.dumps(value))
            definitions[label] = path.read_bytes()
        return definitions

    def execute(self, environment, action):
        return subprocess.run(["bash", str(ROOT / "native/swift/tools/install-native.sh"), action], env=environment, capture_output=True, text=True, timeout=20)

    def test_plan_and_busy_preflight_never_touch_services_or_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            plan = self.execute(environment, "--plan")
            self.assertEqual(plan.returncode, 0, plan.stderr)
            self.assertFalse((directory / "calls").exists())
            environment["UNIAPI_FIXTURE_BUSY"] = "1"
            refused = self.execute(environment, "--install")
            self.assertNotEqual(refused.returncode, 0)
            self.assertFalse((directory / "calls").exists())
            self.assertEqual((directory / "Applications/UniApi.app/old-app").read_text(), "retained")

    def test_coordinated_retirement_refusal_preserves_installation_and_never_bootstraps(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            environment["UNIAPI_FIXTURE_RETIRE_REFUSE"] = "1"
            result = self.execute(environment, "--install")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Native transfer refused", result.stderr)
            self.assertEqual((directory / "Applications/UniApi.app/old-app").read_text(), "retained")
            self.assertEqual((directory / "LaunchAgents/app.devved.uniapi-server.plist").read_text(), "old app.devved.uniapi-server")
            commands = (directory / "calls").read_text().splitlines()
            self.assertFalse(any(line.startswith(("bootout ", "bootstrap ", "retire-native-install")) for line in commands))

    def test_foreign_native_owner_refuses_rollback_and_keeps_app_and_definitions(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            environment.update(UNIAPI_FIXTURE_FAIL_SHIM="1", UNIAPI_FIXTURE_FOREIGN_NATIVE="1")
            result = self.execute(environment, "--install")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("recovery is incomplete", result.stderr)
            self.assertTrue((directory / "Applications/UniApi.app/Contents/MacOS/UniApiNative").is_file())
            self.assertIn("UNIAPI_NATIVE_INSTALL_NONCE", (directory / "LaunchAgents/app.devved.uniapi-server.plist").read_text())
            commands = (directory / "calls").read_text().splitlines()
            self.assertEqual(sum(line.startswith("bootstrap ") for line in commands), 2)
            self.assertFalse(any(line.startswith("bootout ") for line in commands))

    def test_operator_definition_change_survives_refused_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            environment.update(UNIAPI_FIXTURE_FAIL_SHIM="1", UNIAPI_FIXTURE_OPERATOR_DEFINITION="1")
            result = self.execute(environment, "--install")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("operator bytes retained", result.stderr)
            self.assertIn("recovery is incomplete", result.stderr)
            self.assertEqual((directory / "LaunchAgents/app.devved.uniapi-server.plist").read_text(), "operator definition")
            self.assertTrue((directory / "Applications/UniApi.app/Contents/MacOS/UniApiNative").is_file())
            commands = (directory / "calls").read_text().splitlines()
            self.assertEqual(sum(line.startswith("bootstrap ") for line in commands), 2)

    def test_unconfirmed_startup_rolls_back_and_preserves_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            state = directory / "state"
            state.mkdir()
            (state / "providers.json").write_text("private fixture configuration")
            environment["UNIAPI_FIXTURE_FAIL_HEALTH"] = "1"
            result = self.execute(environment, "--install")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((directory / "Applications/UniApi.app/old-app").read_text(), "retained")
            self.assertEqual((state / "providers.json").read_text(), "private fixture configuration")
            for label in ("app.devved.uniapi-server", "app.devved.uniapi-shim"):
                self.assertEqual((directory / "LaunchAgents" / (label + ".plist")).read_text(), "old " + label)

    def test_confirmed_transfer_uses_only_native_executables(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            result = self.execute(environment, "--install")
            self.assertEqual(result.returncode, 0, result.stderr)
            for label in ("app.devved.uniapi-server", "app.devved.uniapi-shim"):
                body = (directory / "LaunchAgents" / (label + ".plist")).read_text()
                self.assertNotIn("tsx", body)
                self.assertNotIn("python", body)
            self.assertIn("UniApiNative", (directory / "LaunchAgents/app.devved.uniapi-server.plist").read_text())
            self.assertIn("Helpers/uniapi-shim", (directory / "LaunchAgents/app.devved.uniapi-shim.plist").read_text())

    def test_linked_agent_is_rejected_before_any_service_action(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            victim = directory / "external-settings"
            victim.write_text("keep external bytes")
            agent = directory / "LaunchAgents/app.devved.uniapi-server.plist"
            agent.unlink()
            agent.symlink_to(victim)
            result = self.execute(environment, "--install")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(victim.read_text(), "keep external bytes")
            self.assertFalse((directory / "calls").exists())

    def test_nested_managed_data_links_never_receive_logs_or_backups(self):
        for relative in ("data", "data/logs", "data/native-install-backups"):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                directory, environment = self.fixture(temporary)
                root = Path(environment["UNIAPI_ROOT"])
                link = root / relative
                link.parent.mkdir(parents=True, exist_ok=True)
                outside = directory / "unrelated-data"
                outside.mkdir()
                (outside / "sentinel").write_text("retain unrelated bytes")
                link.symlink_to(outside, target_is_directory=True)
                result = self.execute(environment, "--install")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(sorted(x.name for x in outside.iterdir()), ["sentinel"])
                self.assertFalse((directory / "calls").exists())

    def test_failed_app_restore_never_nests_backup_or_claims_recovery(self):
        for failure in ("restore", "retire_failed"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                directory, environment = self.fixture(temporary)
                environment["UNIAPI_FIXTURE_FAIL_HEALTH"] = "1"
                command = directory / "commands/mv"
                condition = '[[ "$1" == */replaced-UniApi.app ]]' if failure == "restore" else '[[ "${@: -1}" == */failed-native.app ]]'
                command.write_text('#!/bin/bash\nif ' + condition + '; then echo "fixture restoration denied" >&2; exit 1; fi\nexec /bin/mv "$@"\n')
                command.chmod(0o755)
                result = self.execute(environment, "--install")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("recovery is incomplete", result.stderr)
                self.assertNotIn("running PIDs restored", result.stderr)
                self.assertFalse((directory / "Applications/UniApi.app/replaced-UniApi.app").exists())
                self.assertTrue(list((directory / "state/data/native-install-backups").glob("*/replaced-UniApi.app/old-app")))

    def test_dead_shim_prevents_success_and_restores_previous_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            environment["UNIAPI_FIXTURE_FAIL_SHIM"] = "1"
            result = self.execute(environment, "--install")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((directory / "Applications/UniApi.app/old-app").read_text(), "retained")
            self.assertNotIn("Installed the native Swift app", result.stdout)

    def test_failed_recovery_is_reported_instead_of_claiming_restoration(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            environment["UNIAPI_FIXTURE_FAIL_HEALTH"] = "1"
            environment["UNIAPI_FIXTURE_FAIL_RESTORE"] = "1"
            result = self.execute(environment, "--install")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("recovery is incomplete", result.stderr)
            self.assertNotIn("running PIDs restored", result.stderr)
            self.assertTrue((directory / "state/data/native-install-backups").is_dir())

    def test_configured_service_root_is_preserved_and_mismatch_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            configured = directory / "legacy-data"
            configured.mkdir()
            (configured / "providers.json").write_text("retained fixture config")
            environment["UNIAPI_FIXTURE_OLD_ROOT"] = str(configured)
            mismatch = self.execute(environment, "--install")
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertFalse((directory / "calls").exists())
            environment.pop("UNIAPI_ROOT")
            result = self.execute(environment, "--install")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((configured / "providers.json").read_text(), "retained fixture config")
            self.assertIn(str(configured), (directory / "LaunchAgents/app.devved.uniapi-server.plist").read_text())

    def test_custom_storage_and_tool_paths_survive_transfer(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            custom_data = directory / "custom-data"
            custom_data.mkdir()
            config = directory / "custom-routes.json"
            config.write_text("retained fixture providers")
            codex = directory / "custom-codex"
            environment.update(UNIAPI_DATA=str(custom_data), UNIAPI_PROVIDERS=str(config), CODEX_HOME=str(codex))
            result = self.execute(environment, "--install")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(config.read_text(), "retained fixture providers")
            self.assertTrue((custom_data / "native-install-backups").is_dir())
            self.assertFalse((directory / "state/data").exists())
            for label in ("app.devved.uniapi-server", "app.devved.uniapi-shim"):
                body = (directory / "LaunchAgents" / (label + ".plist")).read_text()
                self.assertIn(str(custom_data), body)
                self.assertIn(str(config), body)
                self.assertIn(str(codex), body)

    def test_server_working_directory_fallback_does_not_create_nested_hub_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            configured = directory / "repo"
            environment.pop("UNIAPI_ROOT")
            environment["FIXTURE_WORKING_DIRECTORY"] = str(configured / "server")
            result = self.execute(environment, "--install")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((configured / "data/native-install-backups").is_dir())
            self.assertFalse((configured / "server/data").exists())

    def test_native_plan_and_busy_refusal_never_retire_or_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            originals = self.native_installation(directory, environment)
            plan = self.execute(environment, "--plan")
            self.assertEqual(plan.returncode, 0, plan.stderr)
            prepared = json.loads(plan.stdout.splitlines()[0])
            self.assertEqual(prepared["kind"], "native")
            self.assertEqual(prepared["oldInstance"], environment["UNIAPI_FIXTURE_OLD_NONCE"])
            self.assertFalse(prepared["safeToInstall"])
            self.assertFalse((directory / "calls").exists())
            self.assertFalse((directory / "state").exists())
            environment["UNIAPI_FIXTURE_BUSY"] = "1"
            refused = self.execute(environment, "--install")
            self.assertNotEqual(refused.returncode, 0)
            self.assertFalse((directory / "calls").exists())
            for label, raw in originals.items():
                self.assertEqual((directory / "LaunchAgents" / (label + ".plist")).read_bytes(), raw)

    def test_native_update_preserves_all_launch_settings_and_changes_only_nonce(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            originals = self.native_installation(directory, environment)
            result = self.execute(environment, "--install")
            self.assertEqual(result.returncode, 0, result.stderr)
            for label, raw in originals.items():
                expected = plistlib.loads(raw)
                expected["EnvironmentVariables"]["UNIAPI_NATIVE_INSTALL_NONCE"] = "01234567-89AB-CDEF-0123-456789ABCDEF"
                actual = plistlib.loads((directory / "LaunchAgents" / (label + ".plist")).read_bytes())
                self.assertEqual(actual, expected)
            commands = (directory / "calls").read_text().splitlines()
            self.assertEqual(commands.count("retire-native-update"), 1)
            self.assertNotIn("retire-legacy", commands)
            self.assertFalse(any(line.startswith("bootout ") for line in commands))
            self.assertEqual(sum(line.startswith("bootstrap ") for line in commands), 2)

    def test_failed_native_update_restores_exact_definitions_and_verifies_old_nonce(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory, environment = self.fixture(temporary)
            originals = self.native_installation(directory, environment)
            environment["UNIAPI_FIXTURE_FAIL_SHIM"] = "1"
            result = self.execute(environment, "--install")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("running PIDs restored", result.stderr)
            self.assertNotIn("recovery is incomplete", result.stderr)
            self.assertEqual((directory / "Applications/UniApi.app/old-app").read_text(), "retained")
            for label, raw in originals.items():
                self.assertEqual((directory / "LaunchAgents" / (label + ".plist")).read_bytes(), raw)
            commands = (directory / "calls").read_text().splitlines()
            self.assertEqual(commands.count("retire-native-install"), 1)
            self.assertEqual(commands.count("restored-native-health " + environment["UNIAPI_FIXTURE_OLD_NONCE"]), 2)

    def test_native_update_rechecks_owner_app_and_definitions_before_retirement(self):
        for change in ("kind", "nonce", "definition", "app"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                directory, environment = self.fixture(temporary)
                originals = self.native_installation(directory, environment)
                environment["UNIAPI_FIXTURE_SECOND_PLAN_CHANGE"] = change
                result = self.execute(environment, "--install")
                self.assertNotEqual(result.returncode, 0)
                commands = (directory / "calls").read_text().splitlines()
                self.assertFalse(any(line.startswith(("retire-", "bootout ", "bootstrap ")) for line in commands))
                expected_app = "operator app replacement" if change == "app" else "retained"
                self.assertEqual((directory / "Applications/UniApi.app/old-app").read_text(), expected_app)
                for label, raw in originals.items():
                    path = directory / "LaunchAgents" / (label + ".plist")
                    if change == "definition" and label.endswith("server"):
                        self.assertEqual(path.read_text(), "operator replacement")
                    else: self.assertEqual(path.read_bytes(), raw)

    def test_native_update_requires_fresh_nonce_and_refuses_unowned_candidate_cleanup(self):
        for fault in ("same-nonce", "foreign-candidate", "operator-definition"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                directory, environment = self.fixture(temporary)
                originals = self.native_installation(directory, environment)
                if fault == "same-nonce":
                    environment["UNIAPI_FIXTURE_NEW_NONCE"] = environment["UNIAPI_FIXTURE_OLD_NONCE"]
                else:
                    environment["UNIAPI_FIXTURE_FAIL_SHIM"] = "1"
                    environment["UNIAPI_FIXTURE_FOREIGN_NATIVE" if fault == "foreign-candidate" else "UNIAPI_FIXTURE_OPERATOR_DEFINITION"] = "1"
                result = self.execute(environment, "--install")
                self.assertNotEqual(result.returncode, 0)
                if fault == "same-nonce":
                    self.assertFalse((directory / "calls").exists())
                    for label, raw in originals.items():
                        self.assertEqual((directory / "LaunchAgents" / (label + ".plist")).read_bytes(), raw)
                else:
                    self.assertIn("recovery is incomplete", result.stderr)
                    self.assertNotIn("running PIDs restored", result.stderr)
                    self.assertTrue((directory / "Applications/UniApi.app/Contents/MacOS/UniApiNative").exists())
                    commands = (directory / "calls").read_text().splitlines()
                    self.assertEqual(sum(line.startswith("bootstrap ") for line in commands), 2)
                    self.assertFalse(any(line.startswith("restored-native-health ") for line in commands))
                    if fault == "operator-definition":
                        self.assertEqual((directory / "LaunchAgents/app.devved.uniapi-server.plist").read_text(), "operator definition")


if __name__ == "__main__":
    unittest.main()
