#!/usr/bin/env python3
"""Diagnose hosted CoreSimulator initialization without running application UI tests."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def save(path, proof):
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(proof, indent=2) + "\n")
    temporary.replace(path)


def capture_host_diagnostics(recorder):
    """Bounded read-only evidence; no service resets or desktop interaction."""
    processes = recorder.run(["/bin/ps", "-axo", "pid,ppid,etime,state,comm"], timeout=10)
    recorder.run(["/usr/bin/log", "show", "--last", "5m", "--style", "compact", "--predicate",
                  'process == "CoreSimulatorService" OR process == "simdiskimaged" OR process == "simctl"'], timeout=20)
    # A service stack, unlike a longer timeout, can distinguish an initialization
    # wait from a blocked IPC call. Capture only the isolated runner's services.
    for line in processes.stdout.splitlines():
        if "CoreSimulatorService.xpc/Contents/MacOS/" in line or line.rstrip().endswith("/simdiskimaged"):
            pid = line.split()[0]
            if pid.isdigit():
                destination = recorder.output / ("process-" + pid + ".sample.txt")
                recorder.run(["/usr/bin/sample", pid, "2", "1", "-file", str(destination)], timeout=10)


def run_probe(output, helper, recorder_class, wait, services, predicate, initialize):
    output.mkdir(parents=True, exist_ok=True)
    path = output / "probe.json"
    proof = {"schema_version": 1, "diagnostic_only": True, "started_at": time.time(),
             "phase": "host-initialization", "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
             "simulator_id": None, "simulator_deleted": None, "both_services_ready": False,
             "passed": False, "observations": []}
    save(path, proof)
    recorder = recorder_class(output / "commands")
    identifier = None
    creation_started = False
    name = None
    try:
        initialize(recorder)
        proof["phase"] = "runtime-discovery"; save(path, proof)
        result = recorder.run(["xcrun", "simctl", "list", "runtimes", "-j"], timeout=60, check=True)
        runtimes = json.loads(result.stdout)["runtimes"]
        runtime = max((v for v in runtimes if v["isAvailable"] and ".iOS-" in v["identifier"]),
                      key=lambda v: tuple(map(int, v["version"].split("."))))
        result = recorder.run(["xcrun", "simctl", "list", "devicetypes", "-j"], timeout=60, check=True)
        device = next(v for v in json.loads(result.stdout)["devicetypes"] if v["name"] == "iPad Pro 13-inch (M5)")
        name = "NeoAnki2-ServiceProbe-" + uuid.uuid4().hex[:12]
        proof.update(phase="create", runtime=runtime, simulator_name=name, simulator_deleted=False); save(path, proof)
        creation_started = True
        identifier = recorder.run(["xcrun", "simctl", "create", name, device["identifier"], runtime["identifier"]],
                                  timeout=60, check=True).stdout.strip()
        uuid.UUID(identifier)
        proof.update(simulator_id=identifier, simulator_deleted=False, phase="boot"); save(path, proof)
        recorder.run(["xcrun", "simctl", "boot", identifier], timeout=60, check=True)
        recorder.run(["xcrun", "simctl", "bootstatus", identifier, "-b"], timeout=300, check=True)
        proof["phase"] = "activate-services"; save(path, proof)
        wait(identifier, recorder)
        proof["both_services_ready"] = True
        # Retain a final independent observation of both endpoints together.
        for service, endpoint in services:
            result = recorder.run(["xcrun", "simctl", "spawn", identifier, "launchctl", "print",
                                   f"user/{os.getuid()}/{service}"], check=True)
            ready = predicate(result.stdout, endpoint)
            proof["observations"].append({"service": service, "endpoint": endpoint, "ready": ready,
                                          "command_index": len(recorder.proof["commands"]) - 1})
            save(path, proof)
            if not ready:
                raise RuntimeError("Service readiness regressed before final snapshot: " + service)
        proof.update(phase="complete", passed=True)
        recorder.proof["passed"] = True
    except Exception as error:
        proof["error"] = f"{type(error).__name__}: {error}"
        save(path, proof)
        try:
            capture_host_diagnostics(recorder)
        except Exception as diagnostic_error:
            proof["diagnostic_error"] = str(diagnostic_error)
    finally:
        # A timed-out create may have completed remotely. Reconcile its exact
        # unique name before cleanup; never delete another caller's devices.
        if creation_started and not identifier:
            result = recorder.run(["xcrun", "simctl", "list", "devices", "-j"], timeout=20)
            if result.returncode == 0:
                devices = json.loads(result.stdout)
                matches = [d["udid"] for values in devices["devices"].values() for d in values
                           if d["name"] == name]
                if len(matches) == 1:
                    identifier = matches[0]
                    proof["simulator_id"] = identifier
                elif not matches:
                    proof["simulator_deleted"] = True
        if identifier:
            recorder.run(["xcrun", "simctl", "shutdown", identifier], timeout=60)
            deleted = recorder.run(["xcrun", "simctl", "delete", identifier], timeout=60)
            proof["simulator_deleted"] = deleted.returncode == 0
            if not proof["simulator_deleted"]:
                proof["passed"] = False
                proof["cleanup_error"] = "Owned diagnostic Simulator was not deleted"
        proof["completed_at"] = time.time()
        save(path, proof); recorder.save()
    print("IOS_SERVICE_DIAGNOSTIC_RECEIPT=" + str(path), flush=True)
    return 0 if proof["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        parser.error("Run only on an isolated GitHub-hosted Mac")
    # Write before loading the helper or invoking the first tool so every error
    # has an uploadable receipt, including missing/obsolete tooling.
    args.output.mkdir(parents=True, exist_ok=True)
    path = args.output / "probe.json"
    save(path, {"diagnostic_only": True, "phase": "load-helper", "passed": False})
    try:
        spec = importlib.util.spec_from_file_location("readiness", args.helper)
        readiness = importlib.util.module_from_spec(spec); spec.loader.exec_module(readiness)
        return run_probe(args.output, args.helper, readiness.CommandRecorder, readiness.wait_for_services,
                         readiness.SERVICES, readiness.service_ready, readiness.initialize_host)
    except Exception as error:
        save(path, {"diagnostic_only": True, "phase": "load-helper", "passed": False,
                    "error": f"{type(error).__name__}: {error}"})
        raise


if __name__ == "__main__":
    raise SystemExit(main())
