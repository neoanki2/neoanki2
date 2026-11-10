#!/usr/bin/env python3
"""Diagnose hosted CoreSimulator initialization without running application UI tests."""
import argparse
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import time
import uuid


def save(path, proof):
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(proof, indent=2) + "\n")
    temporary.replace(path)


def select_runtime(runtimes, device):
    """Select a compatible available iOS runtime, independent of inventory order.

    Newer runtimes can be restricted to a single device. Version alone cannot
    establish compatibility: simctl's supportedDeviceTypes is authoritative.
    Equal numeric versions use identifier/build/record as deterministic ties.
    Missing compatibility metadata fails closed instead of trying device create.
    """
    identifier = device.get("identifier")
    if not isinstance(identifier, str) or not identifier:
        raise ValueError("The requested Simulator device has no identifier")
    candidates = []
    for runtime in runtimes:
        if runtime.get("isAvailable") is not True:
            continue
        runtime_id, version = runtime.get("identifier", ""), runtime.get("version", "")
        if not isinstance(runtime_id, str) or not runtime_id.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
            continue
        supported = runtime.get("supportedDeviceTypes")
        if not isinstance(supported, list) or not any(isinstance(v, dict) and v.get("identifier") == identifier for v in supported):
            continue
        numeric_version = tuple(map(int, version.split(".")))
        while len(numeric_version) > 1 and numeric_version[-1] == 0:
            numeric_version = numeric_version[:-1]
        candidates.append(((numeric_version, runtime_id, str(runtime.get("buildversion", "")),
                            json.dumps(runtime, sort_keys=True)), runtime))
    if not candidates:
        raise ValueError("No available iOS runtime explicitly supports device " + identifier)
    return max(candidates, key=lambda item: item[0])[1]


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



def capture_owned_service_diagnostics(identifier, recorder):
    """Find PIDs only in this owned Simulator's retained launchctl responses."""
    services = {"com.apple.dt.automationmode-writer": "/automationmode-writer",
                "com.apple.testmanagerd": "/testmanagerd"}
    found = {}
    for command in reversed(list(recorder.proof["commands"])):
        argv = command["argv"]
        if (len(argv) != 7 or argv[:6] != ["xcrun", "simctl", "spawn", identifier, "launchctl", "print"]):
            continue
        service = argv[-1].rsplit("/", 1)[-1]
        if service not in services or service in found or not command.get("stdout_file"):
            continue
        output = (recorder.output / command["stdout_file"]).read_text()
        pid = re.search(r"^\s*pid = ([0-9]+)\s*$", output, re.M)
        program = re.search(r"^\s*program = (.+)\s*$", output, re.M)
        if not pid or not program or not program[1].strip().endswith(services[service]):
            continue
        found[service] = {"pid": pid[1], "program": program[1].strip(),
                          "launchctl_stdout_file": command["stdout_file"]}
    for service, process in found.items():
        pid, program = process["pid"], process["program"]
        # Verify the live PID still names exactly the captured service before
        # sampling it. Never search/signal another Simulator's same-named process.
        current = recorder.run(["/bin/ps", "-p", pid, "-o", "comm="], timeout=10)
        process["live_program_matches"] = current.returncode == 0 and current.stdout.strip() == program
        if not process["live_program_matches"]:
            continue
        destination = recorder.output / ("owned-" + service + "-" + pid + ".sample.txt")
        sampled = recorder.run(["/usr/bin/sample", pid, "2", "10", "-file", str(destination)], timeout=10)
        process["sample_returncode"] = sampled.returncode
        process["sample_file"] = destination.name if destination.exists() else None
    # Process ID predicates bind the host log to these exact launchctl-derived
    # processes, including launch/loader messages omitted by the old predicate.
    ids = [p["pid"] for p in found.values() if p.get("live_program_matches")]
    if ids:
        predicate = " OR ".join("processIdentifier == " + pid for pid in ids)
        recorder.run(["/usr/bin/log", "show", "--last", "5m", "--style", "compact",
                      "--predicate", predicate], timeout=20)
    # No-argument invocation records the installed tool's supported cache
    # operations. It does not update/delete caches or assume an undocumented verb.
    recorder.run(["xcrun", "simctl", "runtime", "dyld_shared_cache"], timeout=20)
    return found


def run_probe(output, helper, recorder_class, wait, services, predicate, initialize, prepare_dyld_cache=False):
    output.mkdir(parents=True, exist_ok=True)
    path = output / "probe.json"
    proof = {"schema_version": 1, "diagnostic_only": True, "started_at": time.time(),
             "phase": "host-initialization", "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
             "simulator_id": None, "simulator_deleted": None, "both_services_ready": False,
             "passed": False, "observations": [], "prepare_dyld_cache_requested": prepare_dyld_cache}
    save(path, proof)
    recorder = recorder_class(output / "commands")
    identifier = None
    creation_started = False
    name = None
    try:
        initialize(recorder)
        if prepare_dyld_cache:
            # Apple's Xcode 26.1.1 release-note workaround for cold boot after
            # macOS upgrades. This is a labeled diagnostic experiment, not an
            # inferred root cause or a replacement for service/UI readiness.
            proof["phase"] = "prepare-dyld-cache"; save(path, proof)
            recorder.run(["xcrun", "simctl", "runtime", "dyld_shared_cache", "update", "--all"],
                         timeout=300, check=True)
            proof["dyld_cache_update_completed"] = True
        proof["phase"] = "runtime-discovery"; save(path, proof)
        result = recorder.run(["xcrun", "simctl", "list", "runtimes", "-j"], timeout=60, check=True)
        runtimes = json.loads(result.stdout)["runtimes"]
        result = recorder.run(["xcrun", "simctl", "list", "devicetypes", "-j"], timeout=60, check=True)
        device = next(v for v in json.loads(result.stdout)["devicetypes"] if v["name"] == "iPad Pro 13-inch (M5)")
        proof["device"] = device; save(path, proof)
        runtime = select_runtime(runtimes, device)
        name = "NeoAnki2-ServiceProbe-" + uuid.uuid4().hex[:12]
        compatibility = next(v for v in runtime["supportedDeviceTypes"]
                             if isinstance(v, dict) and v.get("identifier") == device["identifier"])
        proof.update(phase="create", runtime=runtime, simulator_name=name, simulator_deleted=False,
                     runtime_selection={"rule": "available iOS runtime explicitly supporting the selected device; numeric version then identifier/build/record tie-break",
                                        "compatibility_source": "supportedDeviceTypes", "matched_device": compatibility})
        save(path, proof)
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
            if identifier:
                proof["owned_service_diagnostics"] = capture_owned_service_diagnostics(identifier, recorder)
                save(path, proof)
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
    parser.add_argument("--prepare-dyld-cache", action="store_true",
                        help="CI-only diagnostic experiment: complete Apple runtime cache update before boot")
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
                         readiness.SERVICES, readiness.service_ready, readiness.initialize_host, args.prepare_dyld_cache)
    except Exception as error:
        save(path, {"diagnostic_only": True, "phase": "load-helper", "passed": False,
                    "error": f"{type(error).__name__}: {error}"})
        raise


if __name__ == "__main__":
    raise SystemExit(main())
