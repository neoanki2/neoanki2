#!/usr/bin/env python3
"""Review the Apple TestFlight build in its new, caller-owned sandbox container."""
import argparse
import importlib.util
import json
import os
import stat
from pathlib import Path
import plistlib
import shutil
import uuid

spec = importlib.util.spec_from_file_location("mac_store", Path(__file__).with_name("release-macos-app-store.py"))
mac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mac)

testflight_spec = importlib.util.spec_from_file_location("mac_testflight", Path(__file__).with_name("validate-macos-testflight.py"))
testflight = importlib.util.module_from_spec(testflight_spec)
testflight_spec.loader.exec_module(testflight)


def fresh_container_baseline(container):
    """Apple may precreate a sandbox during installation, before any app launch."""
    if not container.exists():
        return {"state": "absent", "regular_files": [], "symlinks": {}}
    if container.is_symlink() or not container.is_dir():
        raise mac.ReleaseError("Store container is not a regular sandbox directory")
    files, links = [], {}
    def inaccessible(error):
        raise mac.ReleaseError("Cannot inspect sandbox app state: " + str(error))
    for current, directories, names in os.walk(container, followlinks=False, onerror=inaccessible):
        for name in sorted(directories + names):
            path = Path(current) / name
            relative = path.relative_to(container).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                if relative in (".com.apple.containermanagerd.metadata.plist", "Data", "Data/Library",
                                "Data/Library/Application Support", "Data/Library/Preferences"):
                    raise mac.ReleaseError("Store app storage is redirected; cannot prove an ordinary fresh install")
                links[relative] = os.readlink(path)
                if name in directories: directories.remove(name)
            elif stat.S_ISREG(mode):
                if relative != ".com.apple.containermanagerd.metadata.plist":
                    raise mac.ReleaseError("Store container has existing app state; use an isolated macOS test account")
                # macOS protects this installer-owned metadata from reading.
                # Its presence is not app state; never request broader access.
                files.append({"path": relative, "bytes": path.stat().st_size,
                              "contents_inspected": False, "owner": "macOS container manager"})
            elif not stat.S_ISDIR(mode):
                raise mac.ReleaseError("Unexpected sandbox entry; cannot establish a fresh install")
    return {"state": "installer-created-empty", "regular_files": files, "symlinks": links}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--installed-app", type=Path, required=True,
                        help="Apple-re-signed app installed by TestFlight; never the raw distribution export")
    args = parser.parse_args()
    candidate = args.candidate.expanduser().resolve()
    output = (args.output or mac.ROOT / ".build/macos-store-review" / uuid.uuid4().hex[:12]).resolve()
    if output.exists(): parser.error("Use a fresh review output directory")
    output.mkdir(parents=True)
    binary_candidate = Path(json.loads((candidate / "release.json").read_text()).get("binary_candidate", candidate)).resolve()
    exported_app = binary_candidate / "export/NeoAnki2.app"
    app = args.installed_app.expanduser().resolve()
    binary = app / "Contents/MacOS/NeoAnki2"
    state = json.loads((candidate / "release.json").read_text())
    if state.get("source_sha256") != mac.release.source_snapshot()[0]:
        raise mac.ReleaseError("Store source changed since export")
    if mac.digest(exported_app / "Contents/MacOS/NeoAnki2") != state["phases"]["export"]["executable_sha256"]:
        raise mac.ReleaseError("Retained distribution export changed")
    identity = testflight.validate_testflight_app(app, exported_app, mac.testflight_expected_identity(state))
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != mac.APP_ID:
        raise mac.ReleaseError("Store review bundle identity is incorrect")
    mac.run(["codesign", "--verify", "--strict", str(app)])
    ent = plistlib.loads(mac.run(["codesign", "-d", "--entitlements", ":-", str(app)]))
    if ent.get("com.apple.security.app-sandbox") is not True:
        raise mac.ReleaseError("Store review requires App Sandbox")
    container = Path.home() / "Library/Containers" / mac.APP_ID
    baseline = fresh_container_baseline(container)
    derived = output / "derived-data"
    result = output / "review.xcresult"
    receipt = {"app_source_sha256": mac.application_source(), "source_sha256": state["source_sha256"],
        "configuration": "AppStore", "optimization": "-O", "launch_arguments": [], "launch_environment": {},
        "fresh_install": True, "test_fixture_seeded": False, "result": str(result),
        "executable": {"path": str(binary), "sha256": mac.digest(binary)},
        "testflight_identity": identity, "container": str(container),
        "fresh_container_baseline": baseline, "passed": False}
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
        if testflight.validate_testflight_app(app, exported_app, mac.testflight_expected_identity(state)) != identity:
            raise mac.ReleaseError("TestFlight app changed during review")
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
