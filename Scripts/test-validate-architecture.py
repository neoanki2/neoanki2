#!/usr/bin/env python3
"""Exercise architecture gate exit handling without compiling or editing sources."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("validate-architecture.sh").resolve()


class ArchitectureGuardTests(unittest.TestCase):
    def exercise(self, rg_status=None):
        with tempfile.TemporaryDirectory(prefix="neoanki-architecture-test-") as directory:
            tools = Path(directory)
            log = tools / "scans.log"
            if rg_status is not None:
                # The scanner is simulated; all control flow is the real gate.
                rg = tools / "rg"
                rg.write_text('#!/bin/bash\nprintf "scan\\n" >> "$NEOANKI_ARCH_SCAN_LOG"\n'
                              + ('printf "source.swift:1:import SwiftUI\\n"\n' if rg_status == 0 else '')
                              + 'exit ' + str(rg_status) + '\n')
                rg.chmod(0o755)
                (tools / "dirname").symlink_to("/usr/bin/dirname")
            result = subprocess.run(["/bin/bash", str(SCRIPT)], capture_output=True, text=True,
                                    env={**os.environ, "PATH": str(tools), "NEOANKI_ARCH_SCAN_LOG": str(log)}, timeout=10)
            scans = log.read_text().splitlines() if log.exists() else []
            return result, scans

    def test_missing_ripgrep_fails_before_any_scan_or_success_message(self):
        result, scans = self.exercise()
        self.assertEqual(result.returncode, 127)
        self.assertIn("requires ripgrep", result.stderr)
        self.assertEqual(scans, [])
        self.assertNotIn("boundaries passed", result.stdout)

    def test_scanner_error_stops_immediately_and_cannot_look_like_no_matches(self):
        result, scans = self.exercise(2)
        self.assertEqual(result.returncode, 2)
        self.assertIn("could not scan", result.stderr)
        self.assertEqual(len(scans), 1)
        self.assertNotIn("boundaries passed", result.stdout)

    def test_no_matches_checks_every_boundary_and_succeeds(self):
        result, scans = self.exercise(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(scans), 12)
        self.assertIn("Architecture boundaries passed", result.stdout)

    def test_forbidden_matches_fail_and_preserve_all_boundary_checks(self):
        result, scans = self.exercise(0)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(scans), 12)
        self.assertEqual(result.stderr.count("Architecture violation:"), 12)
        self.assertIn("source.swift:1:import SwiftUI", result.stderr)
        self.assertNotIn("boundaries passed", result.stdout)


if __name__ == "__main__": unittest.main()
