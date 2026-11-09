#!/usr/bin/env python3
"""Warm XCTest services on a caller-owned Simulator before its runner watchdog starts."""
import argparse
import json
import os
import re
import subprocess
import time


def service_ready(output, endpoint):
    endpoint_state = re.search(r'"' + re.escape(endpoint) + r'"\s*=\s*\{([^}]+)\}', output)
    return (re.search(r'^\s*state = running\s*$', output, re.M) is not None
            and re.search(r'^\s*initialized = 1\s*$', output, re.M) is not None
            and endpoint_state is not None
            and re.search(r'^\s*active = 1\s*$', endpoint_state[1], re.M) is not None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator_id")
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
    device = next((d for values in devices["devices"].values() for d in values if d["udid"] == args.simulator_id), None)
    if not device or not device["name"].startswith("NeoAnki2-") or device["state"] != "Booted":
        parser.error("Expected the booted, disposable NeoAnki2 Simulator owned by the caller")
    for service, endpoint in [("com.apple.dt.automationmode-writer", "com.apple.dt.automationmode.reader"),
                              ("com.apple.testmanagerd", "com.apple.testmanagerd.control")]:
        started = time.monotonic()
        prefix = ["xcrun", "simctl", "spawn", args.simulator_id, "launchctl"]
        label = f"user/{os.getuid()}/{service}"
        subprocess.run([*prefix, "kickstart", "-p", label], check=True, capture_output=True, timeout=args.timeout)
        while time.monotonic() - started < args.timeout:
            result = subprocess.run([*prefix, "print", label], capture_output=True, text=True, timeout=20)
            if result.returncode == 0 and service_ready(result.stdout, endpoint):
                print(f"IOS_TEST_SERVICE_READY={service} elapsed={time.monotonic()-started:.1f}s", flush=True)
                break
            time.sleep(1)
        else:
            raise RuntimeError(f"XCTest service never became initialized with an active endpoint: {service}")


if __name__ == "__main__":
    main()
