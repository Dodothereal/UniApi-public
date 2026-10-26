#!/usr/bin/env python3
"""Private subprocess ownership tests; no native app/window or compiler launch."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("capture_runner", Path(__file__).with_name("run-proof.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class OwnershipTests(unittest.TestCase):
    def test_success_preserves_exit_and_both_output_streams(self):
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "output.log"
            code, stdout = runner.execute([sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr); sys.exit(7)"], 2, log)
            self.assertEqual(code, 7)
            self.assertEqual(stdout, b"out\n")
            self.assertEqual(log.read_bytes(), b"out\nerr\n")

    def test_timeout_retains_partial_output_and_stops_owned_descendant(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            marker, ready, log = root / "late", root / "ready", root / "output.log"
            # The child deliberately closes inherited pipes. Waiting only for
            # parent output would not establish that this descendant stopped.
            child = "import pathlib,time; pathlib.Path(" + repr(str(ready)) + ").write_text('ready'); time.sleep(.7); pathlib.Path(" + repr(str(marker)) + ").write_text('escaped')"
            parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c'," + repr(child) + "],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print('partial',flush=True); time.sleep(10)"
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.execute([sys.executable, "-c", parent], .4, log)
            self.assertTrue(ready.is_file(), "child did not start; timeout control was vacuous")
            self.assertEqual(log.read_bytes(), b"partial\n")
            time.sleep(.8)
            self.assertFalse(marker.exists(), "owned child survived the timeout")


if __name__ == "__main__":
    unittest.main(verbosity=2)
