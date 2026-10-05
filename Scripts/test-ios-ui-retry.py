#!/usr/bin/env python3
"""Verify the actual jq classifier cannot hide real UI or accessibility defects."""
import json
from pathlib import Path
import subprocess
import unittest

CLASSIFIER = Path(__file__).with_name("classify-ios-ui-result.jq")


class IOSUIRetryClassificationTests(unittest.TestCase):
    def classify(self, failures=None, total=2, **attributes):
        summary = {"totalTestCount": total, "testFailures": failures or [], **attributes}
        result = subprocess.run(["jq", "-f", str(CLASSIFIER)], input=json.dumps(summary),
                                text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def test_exact_old_and_new_incomplete_audit_messages_allow_retry(self):
        for text in ["Audit failed to complete in time",
                     'failed: caught error: "Error Domain=com.apple.dt.XCTest.XCTFuture Code=1000 '
                     '"Timed out while running accessibility audit with config: <XCAXAuditConfiguration: 0x1171f5c60>."']:
            with self.subTest(text=text):
                result = self.classify([{"failureText": text}])
                self.assertTrue(result["retryable"])
                self.assertTrue(result["accessibility_audit_timeout"])

    def test_mixed_timeout_and_assertion_or_completed_audit_finding_never_retries(self):
        timeout = {"failureText": "Timed out while running accessibility audit with config: test"}
        for text in ["XCTAssertTrue failed - Save is disabled", "Accessibility audit found insufficient contrast",
                     "Accessibility audit found a hitRegion violation"]:
            with self.subTest(text=text):
                result = self.classify([timeout, {"failureText": text}])
                self.assertFalse(result["retryable"])
                self.assertFalse(result["all_failures_infrastructure"])

    def test_confirmed_zero_tests_and_no_findings_allows_only_infrastructure_retry(self):
        self.assertTrue(self.classify(total=0)["retryable"])
        self.assertFalse(self.classify(total=2)["retryable"])
        self.assertFalse(self.classify(total=None)["retryable"])
        self.assertFalse(self.classify(total=0, failedTests=1)["retryable"])
        self.assertFalse(self.classify(total=0, passedTests=1)["retryable"])
        self.assertFalse(self.classify(total=0, skippedTests=1)["retryable"])
        self.assertFalse(self.classify([{"failureText": "XCTAssertEqual failed"}], total=0)["retryable"])

    def test_launch_and_runner_operation_failures_allow_retry(self):
        for text in ["test runner exited with code 74", "Failed to get launch progress"]:
            with self.subTest(text=text):
                self.assertTrue(self.classify([{"failureText": text}])["retryable"])

    def test_exact_background_assertion_lifecycle_timeout_and_mixed_failure(self):
        text = ("Failed to get background assertion for target app with pid 6975: "
                "Timed out while acquiring background assertion.")
        failure = {"failureText": text}
        result = self.classify([failure])
        self.assertTrue(result["retryable"])
        self.assertTrue(result["app_background_assertion_timeout"])
        for finding in ["XCTAssertTrue failed", "Accessibility audit found insufficient contrast"]:
            self.assertFalse(self.classify([failure, {"failureText": finding}])["retryable"])
        for near_match in [text + " XCTAssertTrue failed", text.replace("6975", "unknown"),
                           "Timed out while acquiring background assertion."]:
            self.assertFalse(self.classify([{"failureText": near_match}])["retryable"])

    def test_generic_timeouts_and_missing_failure_text_fail_closed(self):
        for failure in [{"failureText": "Timed out waiting for app to become idle"},
                        {"failureText": "Timed out waiting for Save"}, {}, "malformed failure"]:
            with self.subTest(failure=failure):
                self.assertFalse(self.classify([failure])["retryable"])

    def test_nested_results_preserve_a_real_finding(self):
        result = self.classify([[{"failureText": "Audit failed to complete in time"}],
                               [{"failureText": "XCTAssertFalse failed"}]] )
        self.assertFalse(result["retryable"])
        self.assertEqual(result["failure_count"], 2)


if __name__ == "__main__":
    unittest.main()
