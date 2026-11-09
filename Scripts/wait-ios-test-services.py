#!/usr/bin/env python3
"""Activate both XCTest services before awaiting their registered Mach endpoints."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

SERVICES = (("com.apple.dt.automationmode-writer", "com.apple.dt.automationmode.reader"),
            ("com.apple.testmanagerd", "com.apple.testmanagerd.control"))


def service_ready(output, endpoint):
    endpoint_state = re.search(r'"' + re.escape(endpoint) + r'"\s*=\s*\{([^}]+)\}', output)
    return (re.search(r'^\s*state = running\s*$', output, re.M) is not None
            and re.search(r'^\s*initialized = 1\s*$', output, re.M) is not None
            and endpoint_state is not None
            and re.search(r'^\s*active = 1\s*$', endpoint_state[1], re.M) is not None)


class CommandRecorder:
    """Save partial command output even when the first CoreSimulator call hangs."""
    def __init__(self, output):
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        self.proof = {"schema_version": 1, "started_at": time.time(), "commands": [],
                      "developer_dir": os.environ.get("DEVELOPER_DIR"), "passed": False}
        self.save()

    def save(self):
        temporary = self.output / "receipt.json.tmp"
        temporary.write_text(json.dumps(self.proof, indent=2) + "\n")
        temporary.replace(self.output / "receipt.json")

    def run(self, command, timeout=20, check=False):
        index = len(self.proof["commands"])
        entry = {"argv": list(command), "started_at": time.time(), "timeout_seconds": timeout}
        self.proof["commands"].append(entry)
        self.save()
        started = time.monotonic()
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
            entry.update(returncode=result.returncode, timed_out=False)
        except subprocess.TimeoutExpired as error:
            def text(value):
                return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
            result = subprocess.CompletedProcess(command, 124, text(error.stdout), text(error.stderr))
            entry.update(returncode=124, timed_out=True)
        except OSError as error:
            result = subprocess.CompletedProcess(command, 127, "", str(error))
            entry.update(returncode=127, timed_out=False)
        entry["elapsed_seconds"] = round(time.monotonic() - started, 3)
        entry["stdout_file"] = f"{index:03d}-stdout.txt"
        entry["stderr_file"] = f"{index:03d}-stderr.txt"
        (self.output / entry["stdout_file"]).write_text(result.stdout)
        (self.output / entry["stderr_file"]).write_text(result.stderr)
        self.save()
        print(f"IOS_SERVICE_COMMAND={index} exit={result.returncode} elapsed={entry['elapsed_seconds']}s "
              + " ".join(command), flush=True)
        if check and result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}); retained diagnostics: {self.output}: {' '.join(command)}")
        return result



def initialize_host(recorder):
    """Finish only setup Xcode explicitly reports pending on an isolated CI VM."""
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("Host setup is restricted to isolated GitHub-hosted Macs")
    recorder.run(["/usr/bin/sw_vers"], check=True)
    recorder.run(["/usr/bin/xcode-select", "-p"], check=True)
    recorder.run(["xcrun", "--find", "simctl"], check=True)
    recorder.run(["xcodebuild", "-version"], timeout=60, check=True)
    status = recorder.run(["xcodebuild", "-checkFirstLaunchStatus"], timeout=60)
    if status.returncode == 124:
        raise RuntimeError("Xcode first-launch status timed out; initialization state is unknown")
    if status.returncode:
        recorder.run(["xcodebuild", "-runFirstLaunch"], timeout=180, check=True)
        recorder.run(["xcodebuild", "-checkFirstLaunchStatus"], timeout=60, check=True)
    recorder.proof["host_initialized"] = True
    recorder.save()


def validate_owned_simulator(simulator_id, recorder):
    result = recorder.run(["xcrun", "simctl", "list", "devices", "-j"], check=True)
    devices = json.loads(result.stdout)
    device = next((d for values in devices["devices"].values() for d in values
                   if d["udid"] == simulator_id), None)
    if not device or not device["name"].startswith("NeoAnki2-") or device["state"] != "Booted":
        raise RuntimeError("Expected the booted, disposable NeoAnki2 Simulator owned by the caller")
    return device


def wait_for_services(simulator_id, recorder, timeout=180, clock=time.monotonic, pause=time.sleep):
    """Start the dependency set first; readiness polling never launches a UI test."""
    prefix = ["xcrun", "simctl", "spawn", simulator_id, "launchctl"]
    labels = [(f"user/{os.getuid()}/{service}", endpoint) for service, endpoint in SERVICES]
    started = clock()
    deadline = started + timeout
    # Do not block on writer registration before testmanagerd can initialize.
    # kickstart without -k preserves an already-running service and its clients.
    for label, _ in labels:
        remaining = deadline - clock()
        if remaining <= 0:
            raise RuntimeError("XCTest service activation deadline expired")
        recorder.run([*prefix, "kickstart", "-p", label], timeout=remaining, check=True)
    pending = dict(labels)
    while pending and clock() < deadline:
        for label, endpoint in list(pending.items()):
            remaining = deadline - clock()
            if remaining <= 0:
                break
            result = recorder.run([*prefix, "print", label], timeout=min(20, remaining))
            if result.returncode == 0 and service_ready(result.stdout, endpoint):
                del pending[label]
                print(f"IOS_TEST_SERVICE_READY={label} elapsed={clock()-started:.1f}s", flush=True)
        if pending and clock() < deadline:
            pause(min(1, deadline - clock()))
    if pending:
        raise RuntimeError("XCTest services lack initialized active endpoints: " + ", ".join(pending))
    recorder.proof["services_ready"] = [label for label, _ in labels]
    recorder.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator_id", nargs="?")
    parser.add_argument("--initialize-host", action="store_true")
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if bool(args.simulator_id) == args.initialize_host:
        parser.error("Provide either a Simulator ID or --initialize-host")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    # Existing CI uploads this directory even if no XCTest bundle was produced.
    output = args.output or (Path(".build/ios-host-initialization") if args.initialize_host else
                             Path(".build/ios-ui-results") / ("service-readiness-" + args.simulator_id))
    recorder = CommandRecorder(output)
    recorder.proof["simulator_id"] = args.simulator_id
    try:
        if args.initialize_host:
            initialize_host(recorder)
            recorder.run(["xcrun", "simctl", "list", "runtimes", "-j"], timeout=60, check=True)
        else:
            recorder.proof["device"] = validate_owned_simulator(args.simulator_id, recorder)
            wait_for_services(args.simulator_id, recorder, args.timeout)
        recorder.proof["passed"] = True
    except Exception as error:
        recorder.proof["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        recorder.proof["completed_at"] = time.time()
        recorder.save()
        print(f"IOS_TEST_SERVICE_RECEIPT={output / 'receipt.json'}", flush=True)


if __name__ == "__main__":
    main()
