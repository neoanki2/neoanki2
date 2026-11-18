#!/usr/bin/env python3
"""Hermetic sensitivity qualification classification and isolation tests."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("editor_sensitivity", Path(__file__).with_name("check-editor-test-sensitivity.py"))
module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class EditorQualificationTests(unittest.TestCase):
    def setUp(self):
        self.mutant = module.MUTANTS[0]
        self.execution = "Build complete!\n◇ Test " + self.mutant.test + "(width:hydrateLater:) started.\n"
        self.issue = ("✘ Test " + self.mutant.test + "(width:hydrateLater:) recorded an issue at Contract.swift:4:2: Expectation failed\n"
                      "↳ " + self.mutant.marker + ": visible glyphs missing\n"
                      "✘ Test " + self.mutant.test + "(width:hydrateLater:) failed after 0.1 seconds.\n")

    def classify(self, text, code=1, timed_out=False):
        return module.support.classify({"exitCode": code, "timedOut": timed_out}, text, self.mutant, {self.mutant.test})[0]

    def test_only_executed_target_assertion_kills_native_mutant(self):
        self.assertEqual(self.classify(self.execution + self.issue), "killed")

    def test_compile_errors_timeouts_and_unexecuted_tests_are_inconclusive(self):
        self.assertEqual(self.classify("error: " + self.mutant.marker), "inconclusive")
        self.assertEqual(self.classify(self.execution + self.issue, timed_out=True), "inconclusive")
        self.assertEqual(self.classify(self.issue), "inconclusive")
        self.assertEqual(self.classify(self.execution, code=0), "survived")

    def test_marker_print_without_the_target_issue_does_not_kill(self):
        wrong = self.issue.replace(self.mutant.marker, "UNRELATED")
        self.assertEqual(self.classify(self.execution + self.mutant.marker + "\n" + wrong), "inconclusive")

    def test_fixture_mutant_requires_a_passing_journey_and_rejected_proof(self):
        result = {"exitCode": 1, "timedOut": False}
        report = {"error": "EDITOR_FIXTURE_PROOF: missing held receipt", "simulatorDeleted": True}
        summary = {"totalTestCount": 1, "passedTests": 1, "skippedTests": 0}
        self.assertEqual(module.ui_classification(result, report, summary, True)[0], "killed")
        self.assertEqual(module.ui_classification(result, report, {}, True)[0], "inconclusive")
        self.assertEqual(module.ui_classification(dict(result, timedOut=True), report, summary, True)[0], "inconclusive")
        self.assertEqual(module.ui_classification(dict(result, exitCode=0), {}, summary, True)[0], "survived")

    def test_inactive_fixture_cannot_be_a_passing_ui_baseline(self):
        status, _ = module.ui_classification({"exitCode": 0, "timedOut": False}, {"status": "passed"},
                                          {"totalTestCount": 1, "passedTests": 1, "skippedTests": 0})
        self.assertEqual(status, "failed")

    def test_missing_anchor_rolls_back_only_isolated_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "input.swift"
            path.write_text("original")
            mutant = module.support.Mutant("broken", "fixture", "test", ("MARKER",), (
                module.support.Edit("input.swift", "original", "changed"),
                module.support.Edit("input.swift", "missing", "bad")))
            with self.assertRaises(RuntimeError): module.support.apply_mutant(root, mutant, root)
            self.assertEqual(path.read_text(), "original")

    def test_termination_runs_python_cleanup_and_allows_the_child_cleanup_budget(self):
        with self.assertRaises(KeyboardInterrupt): module.interrupt(module.signal.SIGTERM, None)
        self.assertGreater(module.UI_RUNNER_TERMINATION_GRACE_SECONDS, 5 + 60 + 60)
        process = Mock(pid=123)
        with patch.object(module.os, "killpg") as kill:
            module.terminate_ui_runner(process)
        kill.assert_called_once_with(123, module.signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=module.UI_RUNNER_TERMINATION_GRACE_SECONDS)

    def test_cancellation_reaps_ui_runner_before_propagating_to_snapshot_cleanup(self):
        process = Mock(pid=123)
        process.wait.side_effect = [KeyboardInterrupt(), 0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(module.subprocess, "Popen", return_value=process), patch.object(module.os, "killpg") as kill:
                with self.assertRaises(KeyboardInterrupt): module.run_ui(root, root, 1)
        kill.assert_called_once_with(123, module.signal.SIGTERM)
        self.assertEqual(process.wait.call_args_list[-1].kwargs,
                         {"timeout": module.UI_RUNNER_TERMINATION_GRACE_SECONDS})

    def test_unresponsive_child_is_killed_only_after_cleanup_grace_and_reaped(self):
        process = Mock(pid=123)
        process.wait.side_effect = [module.subprocess.TimeoutExpired("runner", 150), 0]
        with patch.object(module.os, "killpg") as kill:
            module.terminate_ui_runner(process)
        self.assertEqual([call.args for call in kill.call_args_list],
                         [(123, module.signal.SIGTERM), (123, module.signal.SIGKILL)])
        self.assertEqual(process.wait.call_args_list[-1].args, ())
        self.assertEqual(process.wait.call_args_list[-1].kwargs, {})


if __name__ == "__main__": unittest.main()
