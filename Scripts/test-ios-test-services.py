#!/usr/bin/env python3
"""Test readiness ordering, endpoint validation, and preboot failure evidence."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


readiness = load("readiness_test", "wait-ios-test-services.py")
probe = load("probe_test", "probe-ios-test-services.py")
OWNED_ID = "00000000-0000-0000-0000-000000000001"


def ready(endpoint):
    return f'state = running\ninitialized = 1\nendpoints = {{\n"{endpoint}" = {{\nactive = 1\n}}\n}}'


class FakeRecorder:
    def __init__(self, output):
        self.output = Path(output); self.output.mkdir(parents=True, exist_ok=True)
        self.proof = {"commands": []}
        self.save()

    def save(self):
        (self.output / "receipt.json").write_text(json.dumps(self.proof))

    def run(self, command, timeout=20, check=False):
        self.proof["commands"].append({"argv": command, "timeout_seconds": timeout})
        self.save()
        return subprocess.CompletedProcess(command, 0, "", "")


class ReadinessTests(unittest.TestCase):
    def test_requires_initialized_running_and_exact_active_endpoint(self):
        output = ready("com.apple.dt.automationmode.reader")
        self.assertTrue(readiness.service_ready(output, "com.apple.dt.automationmode.reader"))
        for changed in [output.replace("initialized = 1", "initialized = 0"),
                        output.replace("running", "waiting"), output.replace("active = 1", "active = 0"),
                        output.replace(".reader", ".writer")]:
            self.assertFalse(readiness.service_ready(changed, "com.apple.dt.automationmode.reader"))

    def test_activates_both_before_waiting_for_either(self):
        with tempfile.TemporaryDirectory() as temporary:
            recorder = FakeRecorder(temporary)
            def run(command, timeout=20, check=False):
                recorder.proof["commands"].append({"argv": command})
                endpoint = next((endpoint for service, endpoint in readiness.SERVICES if command[-1].endswith(service)), "")
                return subprocess.CompletedProcess(command, 0, ready(endpoint), "")
            recorder.run = run
            readiness.wait_for_services(OWNED_ID, recorder)
            commands = [c["argv"] for c in recorder.proof["commands"]]
            self.assertEqual([c[-3] for c in commands[:2]], ["kickstart", "kickstart"])
            self.assertEqual([c[-2] for c in commands[2:]], ["print", "print"])
            self.assertEqual(len(recorder.proof["services_ready"]), 2)
            self.assertTrue(all("-k" not in c for c in commands))

    def test_one_missing_endpoint_never_passes_shared_deadline(self):
        with tempfile.TemporaryDirectory() as temporary:
            recorder = FakeRecorder(temporary)
            ticks = [0]
            def clock(): return ticks[0]
            def pause(seconds): ticks[0] += seconds
            def run(command, timeout=20, check=False):
                if "print" in command:
                    ticks[0] += 1
                    service, endpoint = readiness.SERVICES[0]
                    return subprocess.CompletedProcess(command, 0, ready(endpoint) if command[-1].endswith(service) else "initialized = 0", "")
                return subprocess.CompletedProcess(command, 0, "", "")
            recorder.run = run
            with self.assertRaisesRegex(RuntimeError, "testmanagerd"):
                readiness.wait_for_services(OWNED_ID, recorder, timeout=3, clock=clock, pause=pause)
            self.assertNotIn("services_ready", recorder.proof)
            self.assertLessEqual(ticks[0], 3)

    def test_timeout_retains_partial_output_and_unpassed_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            recorder = readiness.CommandRecorder(temporary)
            with patch.object(readiness.subprocess, "run", side_effect=subprocess.TimeoutExpired(["simctl"], 20, b"partial stdout", b"partial stderr")):
                with self.assertRaises(RuntimeError):
                    recorder.run(["simctl"], check=True)
            receipt = json.loads((Path(temporary) / "receipt.json").read_text())
            entry = receipt["commands"][0]
            self.assertTrue(entry["timed_out"])
            self.assertFalse(receipt["passed"])
            self.assertEqual((Path(temporary) / entry["stdout_file"]).read_text(), "partial stdout")
            self.assertEqual((Path(temporary) / entry["stderr_file"]).read_text(), "partial stderr")

    def test_host_initialization_does_not_rerun_setup_when_already_complete(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}):
            recorder = FakeRecorder(temporary)
            readiness.initialize_host(recorder)
            self.assertTrue(recorder.proof["host_initialized"])
            self.assertNotIn(["xcodebuild", "-runFirstLaunch"], [c["argv"] for c in recorder.proof["commands"]])

    def test_host_initialization_requires_positive_post_setup_status(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}):
            recorder = FakeRecorder(temporary)
            original = recorder.run
            calls = [0]
            def run(command, timeout=20, check=False):
                result = original(command, timeout, check)
                if "-checkFirstLaunchStatus" in command:
                    calls[0] += 1
                    if calls[0] == 1: result.returncode = 1
                return result
            recorder.run = run
            readiness.initialize_host(recorder)
            self.assertEqual(calls[0], 2)
            self.assertIn(["xcodebuild", "-runFirstLaunch"], [c["argv"] for c in recorder.proof["commands"]])

    def test_host_status_timeout_never_guesses_setup_state(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}):
            recorder = FakeRecorder(temporary)
            original = recorder.run
            def run(command, timeout=20, check=False):
                result = original(command, timeout, check)
                if "-checkFirstLaunchStatus" in command: result.returncode = 124
                return result
            recorder.run = run
            with self.assertRaisesRegex(RuntimeError, "unknown"):
                readiness.initialize_host(recorder)
            self.assertNotIn("host_initialized", recorder.proof)
            self.assertNotIn(["xcodebuild", "-runFirstLaunch"], [c["argv"] for c in recorder.proof["commands"]])

    def test_rejects_nonowned_or_unbooted_device_before_kickstart(self):
        for name, state in [("Personal iPhone", "Booted"), ("NeoAnki2-owned", "Shutdown")]:
            with tempfile.TemporaryDirectory() as temporary:
                recorder = FakeRecorder(temporary)
                recorder.run = lambda *a, **k: subprocess.CompletedProcess([], 0, json.dumps({"devices": {"runtime": [{"udid": OWNED_ID, "name": name, "state": state}]}}), "")
                with self.assertRaisesRegex(RuntimeError, "disposable"):
                    readiness.validate_owned_simulator(OWNED_ID, recorder)


class ProbeTests(unittest.TestCase):
    def run_probe(self, temporary, failure=None, wait_failure=False):
        recorders = []
        class Recorder(FakeRecorder):
            def __init__(self, output):
                super().__init__(output); recorders.append(self); self.name = None
            def run(self, command, timeout=20, check=False):
                super().run(command, timeout, check)
                if command[1:4] == ["simctl", "list", "runtimes"]:
                    if failure == "runtimes": raise RuntimeError("runtimes timed out")
                    result = {"runtimes": [{"isAvailable": True, "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version": "26.5"}]}
                elif command[1:4] == ["simctl", "list", "devicetypes"]:
                    result = {"devicetypes": [{"name": "iPad Pro 13-inch (M5)", "identifier": "TYPE"}]}
                elif command[1:3] == ["simctl", "create"]:
                    self.name = command[3]
                    if failure == "create": raise RuntimeError("create timed out after remote completion")
                    return subprocess.CompletedProcess(command, 0, OWNED_ID + "\n", "")
                elif command[1:4] == ["simctl", "list", "devices"]:
                    result = {"devices": {"runtime": [{"name": self.name, "udid": OWNED_ID}, {"name": "User iPad", "udid": "DO-NOT-DELETE"}]}}
                elif "print" in command:
                    endpoint = next(endpoint for service, endpoint in readiness.SERVICES if command[-1].endswith(service))
                    return subprocess.CompletedProcess(command, 0, ready(endpoint), "")
                else:
                    return subprocess.CompletedProcess(command, 0, "", "")
                return subprocess.CompletedProcess(command, 0, json.dumps(result), "")
        def wait(*args):
            if wait_failure: raise RuntimeError("writer not ready")
        with patch.object(probe, "capture_host_diagnostics"):
            result = probe.run_probe(Path(temporary), HERE / "wait-ios-test-services.py", Recorder, wait, readiness.SERVICES, readiness.service_ready, lambda recorder: None)
        proof = json.loads((Path(temporary) / "probe.json").read_text())
        commands = [c["argv"] for c in recorders[0].proof["commands"]]
        return result, proof, commands

    def test_runtime_discovery_failure_has_receipt_without_fake_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, proof, commands = self.run_probe(temporary, failure="runtimes")
            self.assertEqual(result, 1)
            self.assertEqual(proof["phase"], "runtime-discovery")
            self.assertIsNone(proof["simulator_id"])
            self.assertIsNone(proof["simulator_deleted"])
            self.assertFalse(proof["passed"])
            self.assertFalse(any("create" in c for c in commands))

    def test_success_requires_final_two_endpoint_snapshots_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, proof, commands = self.run_probe(temporary)
            self.assertEqual(result, 0)
            self.assertTrue(proof["simulator_deleted"])
            self.assertEqual(len(proof["observations"]), 2)
            self.assertTrue(all(o["ready"] for o in proof["observations"]))
            self.assertIn(["xcrun", "simctl", "delete", OWNED_ID], commands)

    def test_service_failure_cleans_up_and_does_not_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, proof, commands = self.run_probe(temporary, wait_failure=True)
            self.assertEqual(result, 1)
            self.assertFalse(proof["both_services_ready"])
            self.assertTrue(proof["simulator_deleted"])
            self.assertIn(["xcrun", "simctl", "delete", OWNED_ID], commands)

    def test_uncertain_create_reconciles_only_its_unique_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, proof, commands = self.run_probe(temporary, failure="create")
            self.assertEqual(result, 1)
            self.assertTrue(proof["simulator_deleted"])
            self.assertIn(["xcrun", "simctl", "delete", OWNED_ID], commands)
            self.assertFalse(any("DO-NOT-DELETE" in c for c in commands))

    def test_guard_rejects_local_run_before_creating_output_or_running_commands(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
            output = Path(temporary) / "must-not-exist"
            with patch("sys.argv", ["probe", "--helper", str(HERE / "wait-ios-test-services.py"), "--output", str(output)]):
                with self.assertRaises(SystemExit) as error: probe.main()
            self.assertEqual(error.exception.code, 2)
            self.assertFalse(output.exists())


if __name__ == "__main__": unittest.main()
