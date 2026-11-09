#!/usr/bin/env python3
"""Capture real App Store screenshots using uniquely owned disposable Simulators."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("ios_release", ROOT / "Scripts/release-ios.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def run(argv, log=None, timeout=900):
    return release.run(argv, log=log, timeout=timeout)


def app_source():
    return release.application_source(release.source_snapshot()[1])


def capture_products(derived):
    products = derived / "Build/Products"
    runs = list(products.glob("*.xctestrun"))
    executable = products / "Debug-iphonesimulator/NeoAnki2.app/NeoAnki2"
    test_binary = products / "Debug-iphonesimulator/NeoAnki2MobileUITests-Runner.app/PlugIns/NeoAnki2MobileUITests.xctest/NeoAnki2MobileUITests"
    if len(runs) != 1 or not executable.is_file() or not test_binary.is_file():
        raise release.ReleaseError("Expected one complete Debug screenshot app/test build")
    configuration = plistlib.loads(runs[0].read_bytes())
    targets = [target for c in configuration.get("TestConfigurations", []) for target in c.get("TestTargets", [])]
    targets = [t for t in targets if t.get("BlueprintName") == "NeoAnki2MobileUITests"]
    if len(targets) != 1 or targets[0].get("UITargetAppPath") != "__TESTROOT__/Debug-iphonesimulator/NeoAnki2.app":
        raise release.ReleaseError("Screenshot xctestrun does not reference the verified Debug app")
    return {"executable": executable, "test_binary": test_binary, "xctestrun": runs[0]}


def record_capture_build(derived, fingerprint):
    if app_source() != fingerprint:
        raise release.ReleaseError("Source changed during screenshot build; rebuild before capture")
    receipt = {"schema_version": 1, "configuration": "Debug", "app_source_sha256": fingerprint,
               "products": {name: {"path": str(path.resolve()), "sha256": release.digest(path)}
                            for name, path in capture_products(derived).items()}}
    release.save_json(derived / "capture-build.json", receipt)
    return receipt


def validate_capture_build(derived, fingerprint):
    path = derived / "capture-build.json"
    if not path.is_file():
        raise release.ReleaseError("--skip-build requires a verified capture-build.json; perform a fresh screenshot build")
    receipt = json.loads(path.read_text())
    if (not isinstance(receipt, dict) or receipt.get("schema_version") != 1 or receipt.get("configuration") != "Debug"
            or receipt.get("app_source_sha256") != fingerprint):
        raise release.ReleaseError("Cached screenshot build belongs to different application or test inputs")
    if not isinstance(receipt.get("products"), dict):
        raise release.ReleaseError("Cached screenshot build products must be an object")
    for name, product in capture_products(derived).items():
        saved = receipt.get("products", {}).get(name, {})
        if (not isinstance(saved, dict) or saved.get("path") != str(product.resolve())
                or saved.get("sha256") != release.digest(product)):
            raise release.ReleaseError("Cached screenshot executable, test binary, or xctestrun changed")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/ios-app-store-screenshots")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if (args.output / "screenshots.json").exists():
        raise release.ReleaseError("Use a fresh --output directory to preserve existing screenshot evidence")
    derived = ROOT / ".build/ios-store-ui"
    fingerprint, _ = release.source_snapshot()
    app_fingerprint = app_source()
    if not args.skip_build:
        # A failed fresh build must never leave a reusable stale attestation.
        (derived / "capture-build.json").unlink(missing_ok=True)
        run(["xcodebuild", "build-for-testing", "-quiet", "-project", str(ROOT / "Xcode/NeoAnkiiOS.xcodeproj"),
             "-scheme", "NeoAnki2MobileUITests", "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
             "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "SWIFT_ENABLE_EXPLICIT_MODULES=NO"],
            log=args.output / "build.log", timeout=1800)
        record_capture_build(derived, app_fingerprint)
    build_receipt = validate_capture_build(derived, app_fingerprint)
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "-j"]))["runtimes"]
    available = [r for r in runtimes if r["isAvailable"] and ".iOS-" in r["identifier"]]
    runtime = max(available, key=lambda r: tuple(map(int, r["version"].split("."))))["identifier"]
    types = {d["name"]: d["identifier"] for d in json.loads(run(["xcrun", "simctl", "list", "devicetypes", "-j"]))["devicetypes"]}
    devices = [("iphone", "iPhone 16 Pro Max", (1320, 2868)),
               ("ipad", "iPad Pro 13-inch (M4)", (2064, 2752))]
    run_file = build_receipt["products"]["xctestrun"]["path"]
    receipt = {"source_sha256": fingerprint, "app_source_sha256": app_fingerprint,
               "capture_build": build_receipt, "devices": {}, "passed": False}
    for family, name, dimensions in devices:
        folder = args.output / family
        folder.mkdir(exist_ok=True)
        result = folder / (uuid.uuid4().hex[:8] + ".xcresult")
        device = run(["xcrun", "simctl", "create", "NeoAnki2-AppStore-" + uuid.uuid4().hex[:10], types[name], runtime]).decode().strip()
        try:
            run(["xcrun", "simctl", "boot", device])
            run(["xcrun", "simctl", "bootstatus", device, "-b"])
            run(["xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--dataNetwork", "wifi",
                 "--wifiMode", "active", "--wifiBars", "3", "--batteryState", "charged", "--batteryLevel", "100"])
            validate_capture_build(derived, app_fingerprint)
            run(["xcodebuild", "test-without-building", "-quiet", "-xctestrun", run_file,
                 "-destination", "platform=iOS Simulator,id=" + device,
                 "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result),
                 "-only-testing:NeoAnki2MobileUITests/MobileAppStoreScreenshotUITests"],
                log=folder / "test.log", timeout=900)
            attachments = folder / ("attachments-" + result.stem)
            run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(attachments)])
            manifest = json.loads((attachments / "manifest.json").read_text())
            screenshots = []
            for test in manifest:
                for attachment in test.get("attachments", []):
                    if attachment.get("suggestedHumanReadableName", "").startswith("appstore-"):
                        source = attachments / attachment["exportedFileName"]
                        title = attachment["suggestedHumanReadableName"]
                        destination = folder / (title if title.endswith(".png") else title + ".png")
                        shutil.copy2(source, destination)
                        # sips reads image properties without altering the captured pixels.
                        properties = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(destination)]).decode()
                        if f"pixelWidth: {dimensions[0]}" not in properties or f"pixelHeight: {dimensions[1]}" not in properties:
                            raise release.ReleaseError("Screenshot dimensions do not match the App Store device class")
                        screenshots.append({"path": str(destination), "sha256": release.digest(destination)})
            if len(screenshots) != 5:
                raise release.ReleaseError(f"Expected five App Store screenshots, got {len(screenshots)}; inspect {attachments}")
            receipt["devices"][family] = {"device": name, "result": str(result), "screenshots": screenshots}
            release.save_json(args.output / "screenshots.json", receipt)
        finally:
            subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", device], check=True, capture_output=True)
    if app_source() != app_fingerprint:
        raise release.ReleaseError("Source changed during screenshot capture; rebuild before publication")
    validate_capture_build(derived, app_fingerprint)
    receipt["passed"] = True
    release.save_json(args.output / "screenshots.json", receipt)
    print("IOS_RELEASE_SCREENSHOTS=" + str(args.output))


if __name__ == "__main__":
    try:
        main()
    except (release.ReleaseError, OSError, ValueError, KeyError) as error:
        print("IOS_RELEASE_SCREENSHOT_ERROR=" + str(error), file=sys.stderr)
        sys.exit(1)
