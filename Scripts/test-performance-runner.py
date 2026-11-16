#!/usr/bin/env python3
"""Exercise real benchmark launchers with isolated, deterministic Swift stubs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class PerformanceRunnerTests(unittest.TestCase):
    def exercise(self, *, timeout=True, failure="", omitted="", missing_core=False, slow=False):
        with tempfile.TemporaryDirectory(prefix="neoanki-performance-runner-") as directory:
            root = Path(directory) / "repo with spaces"
            (root / "Scripts").mkdir(parents=True)
            if not missing_core:
                (root / "NeoAnkiCore").mkdir()
            for name in ("run-performance-tests.sh", "run-performance-tests-slow.sh", "summarize-performance.sh"):
                shutil.copy2(SCRIPTS / name, root / "Scripts" / name)
            binary = Path(directory) / "bin"
            binary.mkdir()
            for name, target in {"bash": "/bin/bash", "dirname": "/usr/bin/dirname",
                                 "mkdir": "/bin/mkdir", "python3": sys.executable}.items():
                (binary / name).symlink_to(target)
            swift = binary / "swift"
            swift.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
layer = "core" if Path.cwd().name == "NeoAnkiCore" else "app"
with open(os.environ["PROBE_LOG"], "a") as log:
    log.write(json.dumps([layer, sys.argv[1:]]) + "\\n")
if os.environ["PROBE_FAILURE"] == layer:
    sys.exit(7)
if layer not in os.environ["PROBE_OMITTED"].split(","):
    with open(os.environ["NEOANKI_PERF_JSON"], "a") as output:
        output.write(json.dumps(dict(layer=layer, flow="fixture", scale="small", durationSeconds=0.1)) + "\\n")
''')
            swift.chmod(0o755)
            if timeout:
                wrapper = binary / "timeout"
                wrapper.write_text('#!/bin/bash\nshift\nexec "$@"\n')
                wrapper.chmod(0o755)
            log = Path(directory) / "calls.jsonl"
            output = Path(directory) / "measurements.ndjson"
            environment = {**os.environ, "PATH": str(binary), "PROBE_LOG": str(log),
                           "PROBE_FAILURE": failure, "PROBE_OMITTED": omitted,
                           "NEOANKI_PERF_OUTPUT": str(output), "NEOANKI_PERF_SCALE": "large" if slow else "small"}
            script = "run-performance-tests-slow.sh" if slow else "run-performance-tests.sh"
            result = subprocess.run(["/bin/bash", str(root / "Scripts" / script)],
                                    cwd=directory, env=environment, capture_output=True, text=True, timeout=10)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_each_package_runs_once_serially_from_another_directory(self):
        for timeout in (False, True):
            with self.subTest(timeout=timeout):
                result, calls = self.exercise(timeout=timeout)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([row[0] for row in calls], ["core", "app"])
                self.assertTrue(all("--no-parallel" in row[1] for row in calls))
                self.assertIn("Performance baseline written", result.stdout)

    def test_package_failure_propagates_and_cannot_report_success(self):
        for timeout in (False, True):
            for failure in ("core", "app"):
                with self.subTest(timeout=timeout, failure=failure):
                    result, calls = self.exercise(timeout=timeout, failure=failure)
                    self.assertEqual(result.returncode, 7, result.stderr)
                    self.assertEqual(len(calls), 1 if failure == "core" else 2)
                    self.assertNotIn("Performance baseline written", result.stdout)

    def test_bad_core_directory_never_runs_the_app_in_its_place(self):
        result, calls = self.exercise(missing_core=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_missing_or_empty_measurements_fail(self):
        for omitted in ("core", "app", "core,app"):
            with self.subTest(omitted=omitted):
                result, _ = self.exercise(omitted=omitted)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Performance baseline written", result.stdout)

    def test_extended_launcher_also_requires_both_packages(self):
        result, calls = self.exercise(slow=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([row[0] for row in calls], ["core", "app"])
        result, _ = self.exercise(slow=True, omitted="core")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
