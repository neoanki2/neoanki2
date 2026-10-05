#!/usr/bin/env python3
"""Review the ordinary Release first-run journey on owned disposable Simulators."""
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("ios_release_review", ROOT / "Scripts/release-ios.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
TEST = "NeoAnki2MobileUITests/MobileProductionReviewJourneyUITests/testCleanInstallCreateStudyAndPersistenceWithoutFixtures"


def application_source():
    # Include the UI test and project configuration that produced the evidence.
    return release.application_source(release.source_snapshot()[1])


def interrupted(signum, _frame):
    raise release.ReleaseError(f"Internal review interrupted by signal {signum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--device", action="append", help="Simulator device type; may be repeated")
    args = parser.parse_args()
    output = (args.output or ROOT / ".build/ios-internal-review" / uuid.uuid4().hex[:12]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / "review.json").exists():
        raise release.ReleaseError("Use a fresh output directory to preserve previous review evidence")
    devices = args.device or ["iPhone 17 Pro Max", "iPad Pro 13-inch (M5)"]
    runtimes = json.loads(release.run(["xcrun", "simctl", "list", "runtimes", "-j"]))["runtimes"]
    available = [runtime for runtime in runtimes if runtime["isAvailable"] and ".iOS-" in runtime["identifier"]]
    if not available:
        raise release.ReleaseError("An available iOS Simulator runtime is required")
    runtime = max(available, key=lambda entry: tuple(map(int, entry["version"].split("."))))
    types = {entry["name"]: entry["identifier"] for entry in
             json.loads(release.run(["xcrun", "simctl", "list", "devicetypes", "-j"]))["devicetypes"]}
    if any(device not in types for device in devices):
        raise release.ReleaseError("A requested Simulator device type is unavailable")
    source = application_source()
    receipt = {"schema_version": 1, "started_at": dt.datetime.now(dt.timezone.utc).isoformat(),
               "source_sha256": release.source_snapshot()[0], "app_source_sha256": source,
               "configuration": "Release", "optimization": "-O", "launch_arguments": [],
               "launch_environment": {}, "test_fixture_seeded": False, "fresh_install": True,
               "runtime": runtime["identifier"], "test": TEST, "devices": [], "passed": False}
    release.save_json(output / "review.json", receipt)
    derived = output / "derived-data"
    env = os.environ.copy()
    env["SDKROOT"] = release.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).decode().strip()
    release.run(["xcodebuild", "build-for-testing", "-quiet", "-project", str(ROOT / "Xcode/NeoAnkiiOS.xcodeproj"),
                 "-scheme", "NeoAnki2MobileUITests", "-configuration", "Release",
                 "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
                 "CODE_SIGNING_ALLOWED=NO", "SWIFT_ENABLE_EXPLICIT_MODULES=NO", "ENABLE_TESTABILITY=YES",
                 "SWIFT_OPTIMIZATION_LEVEL=-O"], timeout=1800, log=output / "build.log", env=env)
    products = derived / "Build/Products"
    runs = list(products.glob("*.xctestrun"))
    if len(runs) != 1:
        raise release.ReleaseError("Expected exactly one Release xctestrun product")
    app = products / "Release-iphonesimulator/NeoAnki2.app/NeoAnki2"
    receipt["simulator_executable_sha256"] = release.digest(app)
    receipt["xctestrun_sha256"] = release.digest(runs[0])
    for index, name in enumerate(devices):
        folder = output / f"device-{index + 1}"
        folder.mkdir()
        identifier = release.run(["xcrun", "simctl", "create", "NeoAnki2-InternalReview-" + uuid.uuid4().hex[:12],
                                  types[name], runtime["identifier"]]).decode().strip()
        entry = {"device": name, "simulator_id": identifier, "passed": False, "cleaned_up": False}
        try:
            receipt["devices"].append(entry)
            release.save_json(output / "review.json", receipt)
            release.run(["xcrun", "simctl", "boot", identifier])
            release.run(["xcrun", "simctl", "bootstatus", identifier, "-b"], timeout=240)
            result = folder / "review.xcresult"
            entry["result_bundle"] = str(result)
            release.run(["xcodebuild", "test-without-building", "-quiet", "-xctestrun", str(runs[0]),
                         "-destination", "platform=iOS Simulator,id=" + identifier,
                         "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result),
                         "-only-testing:" + TEST], timeout=900, log=folder / "test.log", env=env)
            summary = json.loads(release.run(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                             "--path", str(result), "--compact"]))
            release.save_json(folder / "summary.json", summary)
            if (summary.get("totalTestCount") != 1 or summary.get("passedTests") != 1
                    or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0):
                raise release.ReleaseError("The production review journey must run and pass exactly once")
            entry["summary_sha256"] = release.digest(folder / "summary.json")
            attachments = folder / "attachments"
            release.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                         "--output-path", str(attachments)])
            entry["attachments"] = str(attachments)
            entry["passed"] = True
        finally:
            subprocess.run(["xcrun", "simctl", "shutdown", identifier], capture_output=True)
            deleted = subprocess.run(["xcrun", "simctl", "delete", identifier], capture_output=True)
            entry["cleaned_up"] = deleted.returncode == 0
            release.save_json(output / "review.json", receipt)
            if not entry["cleaned_up"]:
                raise release.ReleaseError("Could not delete the owned review Simulator: " + identifier)
    if application_source() != source:
        raise release.ReleaseError("Application or test source changed during review; rebuild and repeat")
    receipt["passed"] = True
    receipt["completed_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    release.save_json(output / "review.json", receipt)
    print("IOS_INTERNAL_REVIEW=" + str(output / "review.json"))
    print("IOS_INTERNAL_REVIEW_STATUS=passed")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        main()
    except (release.ReleaseError, OSError, ValueError, KeyError) as error:
        print("IOS_INTERNAL_REVIEW_ERROR=" + str(error), file=sys.stderr)
        sys.exit(1)
