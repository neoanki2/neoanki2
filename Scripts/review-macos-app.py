#!/usr/bin/env python3
"""Review the signed sandboxed native Store app in its new, caller-owned container."""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import uuid

spec = importlib.util.spec_from_file_location("mac_store", Path(__file__).with_name("release-macos-app-store.py"))
mac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mac)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    candidate = args.candidate.expanduser().resolve()
    output = (args.output or mac.ROOT / ".build/macos-store-review" / uuid.uuid4().hex[:12]).resolve()
    if output.exists(): parser.error("Use a fresh review output directory")
    output.mkdir(parents=True)
    app = candidate / "export/NeoAnki2.app"
    binary = app / "Contents/MacOS/NeoAnki2"
    state = json.loads((candidate / "release.json").read_text())
    if state.get("source_sha256") != mac.release.source_snapshot()[0]:
        raise mac.ReleaseError("Store source changed since export")
    if mac.digest(binary) != state["phases"]["export"]["executable_sha256"]:
        raise mac.ReleaseError("Store review executable differs from the exported candidate")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != mac.APP_ID:
        raise mac.ReleaseError("Store review bundle identity is incorrect")
    mac.run(["codesign", "--verify", "--strict", str(app)])
    ent = plistlib.loads(mac.run(["codesign", "-d", "--entitlements", ":-", str(app)]))
    if ent.get("com.apple.security.app-sandbox") is not True:
        raise mac.ReleaseError("Store review requires App Sandbox")
    container = Path.home() / "Library/Containers" / mac.APP_ID
    if container.exists():
        raise mac.ReleaseError("Store container already exists; use an isolated macOS test account for an ordinary fresh install")
    derived = output / "derived-data"
    result = output / "review.xcresult"
    receipt = {"app_source_sha256": mac.application_source(), "source_sha256": state["source_sha256"],
        "configuration": "AppStore", "optimization": "-O", "launch_arguments": [], "launch_environment": {},
        "fresh_install": True, "test_fixture_seeded": False, "result": str(result),
        "executable": {"path": str(binary), "sha256": mac.digest(binary)}, "container": str(container), "passed": False}
    mac.release.save_json(output / "review.json", receipt)
    mac.run(["xcodebuild", "build-for-testing", "-quiet", "-project", str(mac.ROOT / "UITests/NeoAnki2UITests.xcodeproj"),
             "-scheme", "NeoAnki2UITests", "-testPlan", "FastFunctional", "-destination", "platform=macOS,arch=arm64",
             "-derivedDataPath", str(derived), "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES",
             "CODE_SIGNING_REQUIRED=YES", "SYMROOT=" + str(derived / "Build/Products"),
             "NEOANKI_UI_APP_PATH=" + str(app)], timeout=1200, log=output / "build.log")
    runs = list((derived / "Build/Products").glob("*.xctestrun"))
    if len(runs) != 1: raise mac.ReleaseError("Expected one macOS review xctestrun")
    data = plistlib.loads(runs[0].read_bytes())
    targets = data["TestConfigurations"][0]["TestTargets"]
    target = next(t for t in targets if t.get("BlueprintName") == "NeoAnki2UITests")
    target["UITargetAppPath"] = str(app)
    target["OnlyTestIdentifiers"] = [mac.PRODUCTION_TEST]
    target["EnvironmentVariables"] = {"NEOANKI_MAC_STORE_REVIEW": "1"}
    target["CommandLineArguments"] = []
    target["UITargetAppCommandLineArguments"] = []
    target["UITargetAppEnvironmentVariables"] = {}
    target["UserAttachmentLifetime"] = "keepAlways"
    runs[0].write_bytes(plistlib.dumps(data))
    receipt["xctestrun"] = {"path": str(runs[0]), "sha256": mac.digest(runs[0])}
    mac.release.save_json(output / "review.json", receipt)
    try:
        mac.run(["xcodebuild", "test-without-building", "-quiet", "-xctestrun", str(runs[0]),
                 "-destination", "platform=macOS,arch=arm64", "-resultBundlePath", str(result),
                 "-parallel-testing-enabled", "NO", "-only-testing:NeoAnki2UITests/" + mac.PRODUCTION_TEST],
                timeout=900, log=output / "test.log")
        actual = json.loads(mac.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result)]))
        cases = mac.release.read_test_cases(actual.get("testNodes", []))
        if len(cases) != 1 or cases[0].get("result") != "Passed":
            raise mac.ReleaseError("The ordinary Mac Store review journey did not pass exactly once")
        if mac.application_source() != receipt["app_source_sha256"]:
            raise mac.ReleaseError("Mac source changed during review")
        receipt["passed"] = True
        mac.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                 "--output-path", str(output / "attachments")], timeout=120)
    finally:
        # Never delete an existing user container. A newly created Store library
        # is retained for inspection and explicitly prevents pretending a rerun is fresh.
        receipt["container_created"] = container.exists()
        mac.release.save_json(output / "review.json", receipt)
    print("MACOS_APP_STORE_REVIEW_RECEIPT=" + str(output / "review.json"))


if __name__ == "__main__":
    main()
