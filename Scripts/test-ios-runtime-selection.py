#!/usr/bin/env python3
"""Regression fixtures from failed hosted probe 42703748177; no local Simulator."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("probe", HERE / "probe-ios-test-services.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

# Actual identifier/version/build/compatibility fields from command 005 JSON.
DEVICE = {"name": "iPad Pro 13-inch (M5)", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"}
RESTRICTED = {"isAvailable": True, "version": "27.2", "buildversion": "24B91016s",
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
              "supportedDeviceTypes": [{"name": "iPhone Duo", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}]}
GENERIC = {"isAvailable": True, "version": "27.2", "buildversion": "24B8117",
           "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "supportedDeviceTypes": [DEVICE]}
OWNED = "12345678-1234-1234-1234-123456789abc"


class SelectionTests(unittest.TestCase):
    def test_actual_restricted_first_equal_version_inventory_selects_generic(self):
        self.assertIs(probe.select_runtime([RESTRICTED, GENERIC], DEVICE), GENERIC)
        self.assertIs(probe.select_runtime([GENERIC, RESTRICTED], DEVICE), GENERIC)

    def test_newer_incompatible_runtime_does_not_override_compatible_one(self):
        restricted = {**RESTRICTED, "version": "28.0"}
        self.assertIs(probe.select_runtime([restricted, GENERIC], DEVICE), GENERIC)

    def test_newest_numeric_compatible_version_wins(self):
        older = {**GENERIC, "version": "27.9", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-9"}
        newer = {**GENERIC, "version": "27.10", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-10"}
        self.assertIs(probe.select_runtime([older, newer], DEVICE), newer)

    def test_equal_version_tie_is_deterministic_independent_of_order(self):
        alternative = {**GENERIC, "identifier": GENERIC["identifier"] + "-variant"}
        self.assertEqual(probe.select_runtime([alternative, GENERIC], DEVICE),
                         probe.select_runtime([GENERIC, alternative], DEVICE))
        same_identity = {**GENERIC, "buildversion": "24B8118"}
        self.assertIs(probe.select_runtime([same_identity, GENERIC], DEVICE), same_identity)

    def test_numeric_trailing_zero_version_is_a_tie(self):
        alternative = {**GENERIC, "version": "27.2.0", "identifier": GENERIC["identifier"] + "-alternate"}
        self.assertEqual(probe.select_runtime([GENERIC, alternative], DEVICE),
                         probe.select_runtime([alternative, GENERIC], DEVICE))

    def test_unavailable_non_ios_and_malformed_version_are_excluded(self):
        invalid = [{**GENERIC, "isAvailable": False}, {**GENERIC, "isAvailable": "true"},
                   {**GENERIC, "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-99-0", "version": "99.0"},
                   {**GENERIC, "version": "27.3 beta"}]
        self.assertIs(probe.select_runtime(invalid + [GENERIC], DEVICE), GENERIC)

    def test_missing_or_nonmatching_compatibility_fails_closed(self):
        for value in (None, [], [{"name": DEVICE["name"]}], [DEVICE["identifier"]], [{"identifier": "OTHER"}]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "explicitly supports"):
                probe.select_runtime([{**GENERIC, "supportedDeviceTypes": value}], DEVICE)
        with self.assertRaisesRegex(ValueError, "explicitly supports"):
            probe.select_runtime([RESTRICTED], DEVICE)

    def test_missing_device_id_rejected_and_input_not_mutated(self):
        with self.assertRaises(ValueError): probe.select_runtime([GENERIC], {"name": DEVICE["name"]})
        original = copy.deepcopy([RESTRICTED, GENERIC])
        probe.select_runtime(original, DEVICE)
        self.assertEqual(original, [RESTRICTED, GENERIC])


class ProbeIntegrationTests(unittest.TestCase):
    def run_fake(self, directory, runtimes):
        recorders = []
        class Recorder:
            def __init__(self, output):
                self.output = output; output.mkdir(parents=True)
                self.proof = {"commands": []}; recorders.append(self)
            def save(self): pass
            def run(self, argv, timeout=20, check=False):
                self.proof["commands"].append({"argv": argv})
                if argv[1:4] == ["simctl", "list", "runtimes"]: data = json.dumps({"runtimes": runtimes})
                elif argv[1:4] == ["simctl", "list", "devicetypes"]: data = json.dumps({"devicetypes": [DEVICE]})
                elif argv[1:3] == ["simctl", "create"]: data = OWNED
                else: data = "endpoint-ready"
                return subprocess.CompletedProcess(argv, 0, data, "")
        with patch.object(probe, "capture_host_diagnostics"):
            status = probe.run_probe(Path(directory), HERE / "probe-ios-test-services.py", Recorder,
                                     lambda *a: None, [("writer", "writer-endpoint"), ("manager", "manager-endpoint")],
                                     lambda output, endpoint: output == "endpoint-ready", lambda recorder: None)
        return status, json.loads((Path(directory) / "probe.json").read_text()), recorders[0].proof["commands"]

    def test_selected_identity_and_compatibility_are_retained_before_create(self):
        with tempfile.TemporaryDirectory() as directory:
            status, proof, commands = self.run_fake(directory, [RESTRICTED, GENERIC])
        self.assertEqual(status, 0)
        created = next(c["argv"] for c in commands if c["argv"][1:3] == ["simctl", "create"])
        self.assertEqual(created[-2:], [DEVICE["identifier"], GENERIC["identifier"]])
        self.assertEqual(proof["runtime"], GENERIC)
        self.assertEqual(proof["device"], DEVICE)
        self.assertEqual(proof["runtime_selection"]["matched_device"], DEVICE)
        self.assertEqual(proof["runtime_selection"]["compatibility_source"], "supportedDeviceTypes")
        self.assertEqual(len(proof["observations"]), 2)
        self.assertTrue(proof["simulator_deleted"])

    def test_no_compatible_runtime_fails_without_create_or_false_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            status, proof, commands = self.run_fake(directory, [RESTRICTED])
        self.assertEqual(status, 1)
        self.assertEqual(proof["phase"], "runtime-discovery")
        self.assertEqual(proof["device"], DEVICE)
        self.assertFalse(proof["passed"])
        self.assertFalse(proof["both_services_ready"])
        self.assertIsNone(proof["simulator_deleted"])
        self.assertFalse(any(c["argv"][1:3] == ["simctl", "create"] for c in commands))


if __name__ == "__main__": unittest.main()
