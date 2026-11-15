#!/usr/bin/env python3
"""Hermetic parser and isolation checks; no Swift build or live app is invoked."""
import importlib.util
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("sync_sensitivity", Path(__file__).with_name("check-sync-test-sensitivity.py"))
module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class SensitivityQualificationTests(unittest.TestCase):
    def setUp(self):
        self.mutant = module.MUTANTS[0]
        self.result = {"timedOut": False, "exitCode": 1}
        self.execution = "Build complete! (0.2s)\n◇ Test " + self.mutant.test + "() started.\n"
        self.issue = ("✘ Test " + self.mutant.test + "() recorded an issue at Contract.swift:12:3: Expectation failed\n"
                      "↳ " + self.mutant.marker + ": missing durable record\n"
                      "✘ Test " + self.mutant.test + "() failed after 0.2 seconds.\n")

    def classify(self, log, result=None):
        return module.classify(result or self.result, log, self.mutant, {self.mutant.test})[0]

    def test_expected_executed_assertion_kills_mutant(self):
        self.assertEqual(self.classify(self.execution + self.issue), "killed")

    def test_compile_error_with_marker_is_inconclusive(self):
        self.assertEqual(self.classify("error: " + self.mutant.marker + "\n"), "inconclusive")

    def test_marker_printed_before_unrelated_issue_is_inconclusive(self):
        log = self.execution + self.mutant.marker + "\n" + self.issue.replace(self.mutant.marker, "UNRELATED")
        self.assertEqual(self.classify(log), "inconclusive")

    def test_process_timeout_is_not_a_kill_even_after_assertion(self):
        result = {"timedOut": True, "exitCode": -15}
        self.assertEqual(self.classify(self.execution + self.issue, result), "inconclusive")

    def test_successful_mutant_survives(self):
        self.assertEqual(self.classify(self.execution, {"timedOut": False, "exitCode": 0}), "survived")

    def test_empty_or_wrong_test_baseline_is_not_passed(self):
        status, _ = module.classify({"timedOut": False, "exitCode": 0},
                                    "Build complete!\nTest run with 1 test passed\n", None, {self.mutant.test})
        self.assertEqual(status, "inconclusive")

    def test_failed_baseline_is_not_a_killed_mutant(self):
        status, _ = module.classify(self.result, self.execution + self.issue, None, {self.mutant.test})
        self.assertEqual(status, "failed")

    def test_crash_after_expected_issue_is_not_a_killed_mutant(self):
        self.assertEqual(self.classify(self.execution + self.issue + "error: Exited with unexpected signal code 11\n"),
                         "inconclusive")

    def test_campaign_ignores_callers_seed_replay_and_artifact_controls(self):
        inherited = {"NEOANKI_SYNC_CONTRACT_REPLAY": "/caller/replay.json",
                     "NEOANKI_SYNC_CONTRACT_SEED": "999", "NEOANKI_SYNC_CONTRACT_SEEDS": "128",
                     "NEOANKI_SYNC_CONTRACT_STEPS": "1000", "NEOANKI_SYNC_CONTRACT_SEED_BASE": "700",
                     "NEOANKI_SYNC_CONTRACT_ARTIFACTS": "/caller/evidence"}
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, inherited):
            environment, recorded = module.contract_environment(Path(folder) / "contract-artifacts")
            self.assertNotIn("NEOANKI_SYNC_CONTRACT_REPLAY", environment)
            self.assertNotIn("NEOANKI_SYNC_CONTRACT_SEED", environment)
            self.assertEqual(environment["NEOANKI_SYNC_CONTRACT_SEEDS"], "2")
            self.assertEqual(environment["NEOANKI_SYNC_CONTRACT_STEPS"], "12")
            self.assertEqual(environment["NEOANKI_SYNC_CONTRACT_SEED_BASE"], "0")
            self.assertEqual(environment["NEOANKI_SYNC_CONTRACT_ARTIFACTS"],
                             str((Path(folder) / "contract-artifacts").resolve()))
            self.assertEqual({key: environment[key] for key in recorded}, recorded)
            self.assertEqual(os.environ["NEOANKI_SYNC_CONTRACT_ARTIFACTS"], "/caller/evidence")

    def test_failed_second_anchor_restores_first_edit(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "source"
            source.mkdir()
            output = Path(folder) / "output"
            output.mkdir()
            path = source / "input.swift"
            path.write_text("original")
            mutant = module.Mutant("broken-anchor", "test", "test", ("MARKER",), (
                module.Edit("input.swift", "original", "changed"),
                module.Edit("input.swift", "missing-anchor", "never")))
            with self.assertRaises(RuntimeError):
                module.apply_mutant(source, mutant, output)
            self.assertEqual(path.read_text(), "original")

    def test_mutation_cannot_follow_a_symlink_out_of_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "source"
            source.mkdir()
            external = root / "external.swift"
            external.write_text("original")
            (source / "input.swift").symlink_to(external)
            mutant = module.Mutant("escape", "test", "test", ("MARKER",), (
                module.Edit("input.swift", "original", "changed"),))
            with self.assertRaises(RuntimeError):
                module.apply_mutant(source, mutant, root)
            self.assertEqual(external.read_text(), "original")

    def test_snapshot_preserves_dirty_and_untracked_source_without_changing_index(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            checkout, source, output = root / "checkout", root / "snapshot", root / "evidence"
            checkout.mkdir()
            output.mkdir()
            with patch.object(module, "ROOT", checkout):
                module.git("init", "--quiet")
                module.git("config", "user.email", "fixture@example.invalid")
                module.git("config", "user.name", "Isolation fixture")
                (checkout / "Sources").mkdir()
                (checkout / "Sources/Tracked.swift").write_text("base\n")
                (checkout / ".gitignore").write_text(".build/\n")
                module.git("add", ".")
                module.git("commit", "--quiet", "-m", "fixture")
                (checkout / "Sources/Tracked.swift").write_text("dirty\n")
                (checkout / "Tests").mkdir()
                (checkout / "Tests/New.swift").write_text("new task test\n")
                (checkout / ".build").mkdir()
                (checkout / ".build/cache").write_text("must not copy")
                before = module.git("status", "--porcelain")
                try:
                    result = module.snapshot(source, output)
                    self.assertEqual((source / "Sources/Tracked.swift").read_text(), "dirty\n")
                    self.assertEqual((source / "Tests/New.swift").read_text(), "new task test\n")
                    self.assertFalse((source / ".build").exists())
                    self.assertEqual(module.git("status", "--porcelain"), before)
                    self.assertFalse(module.git("diff", "--cached"))
                    self.assertEqual([item["path"] for item in result["untrackedFiles"]], ["Tests/New.swift"])
                    with tarfile.open(output / "untracked-source.tar.gz") as archive:
                        self.assertEqual(archive.extractfile("Tests/New.swift").read(), b"new task test\n")
                finally:
                    if source.exists():
                        module.git("worktree", "remove", "--force", str(source))


if __name__ == "__main__":
    unittest.main()
