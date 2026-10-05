#!/usr/bin/env python3
"""Verify review failures cannot leak a Simulator or produce passing evidence."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("ios_review_tests", Path(__file__).with_name("review-ios-app.py"))
review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review)


class InternalReviewSafetyTests(unittest.TestCase):
    def exercise_failure(self, *, fail_test=False, fail_receipt=False, summary=None):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "review"
            cleanup = []
            saves = 0
            original_save = review.release.save_json

            def save(path, value):
                nonlocal saves
                saves += 1
                if fail_receipt and saves == 2:
                    raise OSError("Disk full while recording the newly created Simulator")
                original_save(path, value)

            def run(argv, **_kwargs):
                if argv[1:4] == ["simctl", "list", "runtimes"]:
                    return json.dumps({"runtimes": [{"isAvailable": True, "identifier": "fake.iOS-26-5", "version": "26.5"}]}).encode()
                if argv[1:4] == ["simctl", "list", "devicetypes"]:
                    return json.dumps({"devicetypes": [{"name": "Test iPhone", "identifier": "fake.phone"}]}).encode()
                if "--show-sdk-path" in argv:
                    return b"/fake/macos-sdk"
                if "build-for-testing" in argv:
                    products = Path(argv[argv.index("-derivedDataPath") + 1]) / "Build/Products"
                    app = products / "Release-iphonesimulator/NeoAnki2.app/NeoAnki2"
                    app.parent.mkdir(parents=True)
                    app.write_bytes(b"fake executable")
                    (products / "review.xctestrun").write_bytes(b"fake test configuration")
                elif argv[1:3] == ["simctl", "create"]:
                    return b"OWNED-SIMULATOR"
                elif "test-without-building" in argv:
                    if fail_test:
                        raise review.release.ReleaseError("An actual first-run assertion failed")
                elif "test-results" in argv:
                    return json.dumps(summary or {}).encode()
                return b""

            def cleaned(argv, **_kwargs):
                cleanup.append(argv)
                return subprocess.CompletedProcess(argv, 0)

            with patch.object(sys, "argv", ["review-ios-app.py", "--output", str(output), "--device", "Test iPhone"]), \
                 patch.object(review, "application_source", return_value="application-source"), \
                 patch.object(review.release, "source_snapshot", return_value=("source", [])), \
                 patch.object(review.release, "run", side_effect=run), \
                 patch.object(review.release, "save_json", side_effect=save), \
                 patch.object(review.subprocess, "run", side_effect=cleaned):
                with self.assertRaises((review.release.ReleaseError, OSError)):
                    review.main()
            self.assertIn(["xcrun", "simctl", "shutdown", "OWNED-SIMULATOR"], cleanup)
            self.assertIn(["xcrun", "simctl", "delete", "OWNED-SIMULATOR"], cleanup)
            receipt = json.loads((output / "review.json").read_text())
            self.assertFalse(receipt["passed"])
            self.assertFalse(receipt["devices"][0]["passed"])
            self.assertTrue(receipt["devices"][0]["cleaned_up"])

    def test_receipt_write_failure_after_create_still_deletes_owned_simulator(self):
        self.exercise_failure(fail_receipt=True)

    def test_real_journey_failure_still_deletes_owned_simulator(self):
        self.exercise_failure(fail_test=True)

    def test_missing_summary_counts_cannot_pass(self):
        self.exercise_failure(summary={"result": "Passed"})

    def test_skipped_journey_cannot_pass(self):
        self.exercise_failure(summary={"totalTestCount": 1, "passedTests": 0, "failedTests": 0, "skippedTests": 1})


if __name__ == "__main__":
    unittest.main()
