#!/usr/bin/env python3
"""Resumable App Store archive, export, upload, submission, and status workflow."""
import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "com.neoanki2.ios"
WIDGET_ID = APP_ID + ".widget"
TEAM = "637635WK8L"
API = "https://api.appstoreconnect.apple.com/v1/"
SIGNING = Path.home() / "Library/Application Support/NeoAnki2 Signing"
PHYSICAL_ACCEPTANCE = ("two_device_sync", "widgets", "reminders", "testflight_install")
INTERNAL_REVIEW_SCOPES = {
    "product": {"fresh_install", "primary_journey", "ipad_layout", "permissions", "reminders_widgets_sync"},
    "compliance": {"metadata", "screenshots", "privacy", "age_rating", "rejection_remediation"},
}
PRODUCTION_REVIEW_TEST = "MobileProductionReviewJourneyUITests/testCleanInstallCreateStudyAndPersistenceWithoutFixtures"
SPEC = importlib.util.spec_from_file_location("iphone_signing", ROOT / "Scripts/deploy-iphone.py")
SIGNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNER)


class ReleaseError(Exception):
    pass


def run(argv, timeout=60, log=None, env=None):
    try:
        if log:
            with Path(log).open("wb") as stream:
                result = subprocess.run(argv, cwd=ROOT, stdin=subprocess.DEVNULL,
                                        stdout=stream, stderr=subprocess.STDOUT,
                                        timeout=timeout, env=env)
            if result.returncode:
                raise ReleaseError(f"{argv[0]} failed; see {log}")
            return b""
        result = subprocess.run(argv, cwd=ROOT, stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=timeout, env=env)
        if result.returncode:
            # Avoid printing command lines or Apple authentication output.
            raise ReleaseError(f"{argv[0]} exited with {result.returncode}")
        return result.stdout
    except subprocess.TimeoutExpired:
        raise ReleaseError(f"{argv[0]} timed out") from None


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def json_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def production_input(path):
    name = Path(path).name
    manifest = name in ("Package.swift", "Package.resolved") or (name.startswith("Package@swift-") and name.endswith(".swift"))
    return (manifest or path.startswith(".swiftpm/configuration/")
            or path.startswith(("Sources/", "NeoAnkiCore/", "Platforms/iOS/", "Platforms/iOSWidget/", "Xcode/"))) and "/AppStore/" not in path


def application_source(files):
    # Shared code, resources, project settings, and UI tests must match the
    # tested candidate; documentation/release receipt edits do not rebuild it.
    inputs = [f for f in files if production_input(f["path"]) or f["path"].startswith("Platforms/iOSUITests/")]
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def binary_source(files):
    return json_digest([f for f in files if production_input(f["path"])])


def reuse_binary_candidate(candidate, files, version, build):
    """Explicitly retain an uploaded binary only when all its production inputs match."""
    state = json.loads((candidate / "release.json").read_text())
    old_files = json.loads((candidate / "source.json").read_text())
    if json_digest(old_files) != state["source_sha256"] or binary_source(old_files) != binary_source(files):
        raise ReleaseError("Uploaded binary production inputs changed; prepare and upload a new build")
    if state["version"] != version or (build and state["build"] != build):
        raise ReleaseError("Retained binary version/build differs from the requested candidate")
    phases = state.get("phases", {})
    archive = candidate / "NeoAnki2.xcarchive/Products/Applications/NeoAnki2.app/NeoAnki2"
    ipa = candidate / "export/NeoAnki2.ipa"
    if (phases.get("upload", {}).get("status") != "delivered"
            or not archive.is_file() or digest(archive) != phases.get("archive", {}).get("executable_sha256")
            or not ipa.is_file() or digest(ipa) != phases.get("export", {}).get("ipa_sha256")
            or digest(ipa) != phases["upload"].get("ipa_sha256") or not state.get("build_id")):
        raise ReleaseError("Retained binary lacks matching verified archive/export/upload evidence")
    return state


def checked_evidence(reference, base):
    if not isinstance(reference, dict) or not isinstance(reference.get("path"), str) or not reference["path"]:
        raise ReleaseError("Internal review requires a checksummed evidence file")
    path = Path(reference["path"])
    path = path if path.is_absolute() else base / path
    if not path.is_file() or digest(path) != reference.get("sha256"):
        raise ReleaseError("Internal review evidence is missing or changed")
    return path


def object_list(value, label):
    if not isinstance(value, list) or any(not isinstance(entry, dict) for entry in value):
        raise ReleaseError("Internal review " + label + " must be an array of objects")
    return value


def concrete_observation(value, paths):
    detail, ids = value.get("detail"), value.get("evidence_ids")
    return (isinstance(detail, str) and len(detail.strip()) >= 40 and isinstance(ids, list) and bool(ids)
            and all(isinstance(name, str) and name in paths for name in ids))


def read_test_cases(nodes):
    cases = []
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            cases.append(node)
        cases.extend(read_test_cases(node.get("children", [])))
    return cases


def validate_production_capture(proof, path, result):
    if (proof.get("configuration") != "Release" or proof.get("optimization") != "-O"
            or proof.get("launch_arguments") != [] or proof.get("launch_environment") != {}
            or proof.get("test_fixture_seeded") is not False or proof.get("fresh_install") is not True
            or proof.get("test") != "NeoAnki2MobileUITests/" + PRODUCTION_REVIEW_TEST):
        raise ReleaseError("Production review must use an ordinary optimized Release launch without fixtures")
    device = [d for d in object_list(proof.get("devices", []), "production devices")
              if isinstance(d.get("result_bundle"), str) and Path(d["result_bundle"]).resolve() == result.resolve()]
    if len(device) != 1 or device[0].get("cleaned_up") is not True:
        raise ReleaseError("Production review lacks exact cleaned-up disposable Simulator evidence")
    products = path.parent / "derived-data/Build/Products"
    executable = products / "Release-iphonesimulator/NeoAnki2.app/NeoAnki2"
    runs = list(products.glob("*.xctestrun"))
    if (not executable.is_file() or digest(executable) != proof.get("simulator_executable_sha256")
            or len(runs) != 1 or digest(runs[0]) != proof.get("xctestrun_sha256")):
        raise ReleaseError("Production review executable or test configuration is missing or changed")
    configuration = plistlib.loads(runs[0].read_bytes())
    targets = [target for c in configuration.get("TestConfigurations", []) for target in c.get("TestTargets", [])]
    matching = [t for t in targets if t.get("BlueprintName") == "NeoAnki2MobileUITests"]
    if len(matching) != 1:
        raise ReleaseError("Production review xctestrun does not contain the expected test target")
    target = matching[0]
    if ("Release-iphonesimulator/NeoAnki2.app" not in target.get("UITargetAppPath", "")
            or target.get("CommandLineArguments", []) != []
            or target.get("UITargetAppCommandLineArguments", []) != []
            or any(key.startswith("NEOANKI") for field in ("EnvironmentVariables", "UITargetAppEnvironmentVariables")
                   for key in target.get(field, {}))):
        raise ReleaseError("Production review xctestrun injects a debug app, launch arguments, or test fixtures")
    return device[0]


def reviewable_app_info_attributes(attributes):
    # Apple changes `state` when an issue is resolved. These lifecycle fields
    # aren't listing content; age ratings and all other attributes stay bound.
    return {key: value for key, value in attributes.items()
            if key not in ("state", "appStoreState", "appVersionState")}


def validate_internal_review(review, context, output):
    """Check live candidate binding and substantive evidence, never a passed flag.

    Checksums provide integrity, not reviewer authentication. Retain actual
    review transcripts and XCTest bundles; fabricated reports remain misconduct.
    """
    if not isinstance(review, dict):
        raise ReleaseError("Internal review receipt must be an object")
    remediation = object_list(review.get("remediation", []), "remediation")
    context_sha = json_digest(context)
    if review.get("schema_version") != 1 or review.get("context_sha256") != context_sha:
        raise ReleaseError("Internal review is missing or stale for the live source/build/store listing")
    evidence = review.get("evidence", {})
    if not isinstance(evidence, dict) or not evidence:
        raise ReleaseError("Internal review has no inspectable evidence")
    paths = {name: checked_evidence(ref, output) for name, ref in evidence.items()}
    reviewers = object_list(review.get("reviewers", []), "reviewers")
    if any(not isinstance(r.get("role"), str) or not isinstance(r.get("reviewer"), str) for r in reviewers):
        raise ReleaseError("Internal reviewer identity and role must be strings")
    if {r.get("role") for r in reviewers} != set(INTERNAL_REVIEW_SCOPES) or len(reviewers) != 2:
        raise ReleaseError("Internal review requires separate product and compliance reviews")
    if len({r.get("reviewer") for r in reviewers if r.get("reviewer")}) != 2:
        raise ReleaseError("Internal review reviewers must have distinct identities")
    for reviewer in reviewers:
        report_path = checked_evidence(reviewer.get("report"), output)
        report = json.loads(report_path.read_text())
        if (not isinstance(report, dict) or report.get("reviewer") != reviewer["reviewer"] or report.get("role") != reviewer["role"]
                or report.get("context_sha256") != context_sha or report.get("decision") != "approve"
                or report.get("blocking_findings") != []):
            raise ReleaseError("Internal reviewer did not approve this exact candidate without blockers")
        observations = object_list(report.get("observations", []), "observations")
        if any(not isinstance(o.get("scope"), str) for o in observations):
            raise ReleaseError("Internal review observation scope must be a string")
        if {o.get("scope") for o in observations} != INTERNAL_REVIEW_SCOPES[reviewer["role"]]:
            raise ReleaseError("Internal reviewer omitted required review scope")
        for observation in observations:
            if not concrete_observation(observation, paths):
                raise ReleaseError("Internal review observation requires a concrete finding and inspectable evidence")
    tested, production_families = {}, set()
    for entry in object_list(review.get("ui_runs", []), "UI runs"):
        proof_path = checked_evidence(entry.get("capture_receipt"), output)
        proof = json.loads(proof_path.read_text())
        if not isinstance(proof, dict) or not isinstance(entry.get("result"), str):
            raise ReleaseError("UI review receipt must be an object with a result path")
        result = Path(entry.get("result", ""))
        if proof.get("app_source_sha256") != context["app_source_sha256"] or not result.is_dir():
            raise ReleaseError("UI review evidence does not describe this candidate's disposable Simulator run")
        production = entry.get("production") is True
        if production:
            device = validate_production_capture(proof, proof_path, result)
        elif (not isinstance(proof.get("result"), str) or Path(proof["result"]).resolve() != result.resolve()
              or proof.get("simulator_deleted") is not True):
            raise ReleaseError("UI review evidence does not describe this candidate's disposable Simulator run")
        actual = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result)]))
        cases = read_test_cases(actual.get("testNodes", []))
        if not cases or any(case.get("result") != "Passed" for case in cases):
            raise ReleaseError("Internal review XCTest results contain missing, failed, or skipped tests")
        models = {d.get("modelName", "") for d in actual.get("devices", [])}
        family = entry.get("family")
        if family not in ("iphone", "ipad") or not any(
                model.startswith("iPhone" if family == "iphone" else "iPad") for model in models):
            raise ReleaseError("Internal review UI results do not match the claimed device family")
        if production:
            if device.get("simulator_id") not in {d.get("deviceId") for d in actual.get("devices", [])}:
                raise ReleaseError("Production review Simulator identity differs from the actual XCTest run")
            if {case["nodeIdentifier"].removesuffix("()") for case in cases} != {PRODUCTION_REVIEW_TEST}:
                raise ReleaseError("Production review must execute the clean-install journey without unrelated fixture tests")
            production_families.add(family)
        tested.setdefault(family, set()).update(case["nodeIdentifier"].removesuffix("()") for case in cases)
    required = {
        "MobileCardJourneyUITests/testCreateBrowseAndStudyBasicCardJourney",
        "MobileRedesignParityUITests/testAllFieldAuthoringMediaRemovalAndPickerCancellation",
    }
    if production_families != {"iphone", "ipad"}:
        raise ReleaseError("Internal review requires the ordinary Release clean-install journey on both iPhone and iPad")
    rejection = context.get("rejection")
    if rejection:
        required.update(test for issue in rejection["issues"] for test in issue["required_tests"])
        if any(not isinstance(r.get("issue_id"), str) for r in remediation):
            raise ReleaseError("Apple rejection remediation issue ID must be a string")
        if {r.get("issue_id") for r in remediation} != {i["id"] for i in rejection["issues"]}:
            raise ReleaseError("Internal review must resolve every recorded Apple rejection issue")
        for resolution in remediation:
            if not concrete_observation(resolution, paths):
                raise ReleaseError("Apple rejection remediation lacks concrete evidence")
    if any(not required <= tested.get(family, set()) for family in ("iphone", "ipad")):
        raise ReleaseError("Internal review lacks required candidate UI regressions on both iPhone and iPad")
    # Ensure the retained local pixels are exactly the ordered remote assets
    # reviewed; an uploaded old image cannot pass by citing a new capture.
    screenshots = object_list(review.get("screenshots", []), "screenshots")
    expected = {(s["id"], s["source_checksum"].lower()) for s in context["screenshots"]}
    actual_assets = set()
    for screenshot in screenshots:
        if not isinstance(screenshot.get("apple_id"), str):
            raise ReleaseError("Internal review screenshot Apple ID must be a string")
        path = checked_evidence(screenshot, output)
        checksum = hashlib.md5(path.read_bytes()).hexdigest()
        actual_assets.add((screenshot.get("apple_id"), checksum))
    if not expected or actual_assets != expected or len(screenshots) != len(expected):
        raise ReleaseError("Internal review screenshots differ from Apple's exact uploaded images")
    return {"context_sha256": context_sha, "review_sha256": json_digest(review),
            "reviewers": [r["reviewer"] for r in reviewers],
            "remediated_issues": [r["issue_id"] for r in remediation],
            "passed_ui_tests": {family: sorted(tests) for family, tests in tested.items()}}


def select_review_submission(submissions, items_by_submission, version_id, saved_id=None):
    """Reconcile rejected/draft submissions without creating duplicate Apple objects."""
    matching = []
    for submission in submissions:
        if submission["attributes"]["state"] in ("COMPLETE", "CANCELED"):
            continue
        for item in items_by_submission[submission["id"]]:
            related = item.get("relationships", {}).get("appStoreVersion", {}).get("data")
            if related and related["id"] == version_id:
                matching.append((submission, item))
    if len(matching) > 1:
        raise ReleaseError("Multiple active review submissions reference this version; resolve them before resubmitting")
    if matching:
        target, item = matching[0]
        if item["attributes"]["state"] in ("REMOVED", "ACCEPTED"):
            raise ReleaseError("The requested review item is removed or already accepted; it cannot be resubmitted in this submission")
        children = items_by_submission[target["id"]]
        safe_items = all(child["attributes"]["state"] in ("READY_FOR_REVIEW", "ACCEPTED", "REMOVED")
                         or (child["attributes"]["state"] == "REJECTED" and child["attributes"].get("resolved") is True)
                         for child in children)
        if target["attributes"]["state"] not in ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES") or not safe_items:
            raise ReleaseError("Resolve Apple's rejected review item before resubmission; refusing an unresolved or duplicate submission")
        return target, True
    pending = [s for s in submissions if s["attributes"]["state"] not in ("COMPLETE", "CANCELED")]
    if len(pending) == 1 and pending[0]["id"] == saved_id and pending[0]["attributes"]["state"] == "READY_FOR_REVIEW":
        if not items_by_submission[saved_id]:
            return pending[0], False
    if pending:
        raise ReleaseError("Another iOS review submission is active; inspect it before creating a duplicate")
    return None, False


def record_rejections(state, versions, submissions, items_by_submission):
    """A later Ready for Review state must never erase a known Apple rejection."""
    known = set(state.get("rejected_version_ids", []))
    known.update(v["id"] for v in versions if v["attributes"]["appStoreState"] in ("REJECTED", "METADATA_REJECTED"))
    for submission in submissions:
        for item in items_by_submission.get(submission["id"], []):
            relation = item.get("relationships", {}).get("appStoreVersion", {}).get("data")
            if relation and (item["attributes"]["state"] == "REJECTED"
                             or submission["attributes"]["state"] == "UNRESOLVED_ISSUES"):
                known.add(relation["id"])
    state["rejected_version_ids"] = sorted(known)


def require_rejection_record(state, version_id, rejection_path):
    if version_id in state.get("rejected_version_ids", []) and not rejection_path.is_file():
        raise ReleaseError("Preserve Apple's exact written rejection issues even after the version becomes Ready for Review")


@contextlib.contextmanager
def signing_archive(source, output):
    """Keep the verified unsigned archive intact when signing/export is retried."""
    with tempfile.TemporaryDirectory(prefix="signing-", dir=output) as folder:
        archive = Path(folder) / "NeoAnki2.xcarchive"
        shutil.copytree(source, archive, symlinks=True)
        yield archive


@contextlib.contextmanager
def export_keychain_search(keychain):
    """Xcode must select the disposable identity instead of a locked duplicate."""
    def entries():
        return re.findall(r'"([^"]+)"', run(["security", "list-keychains", "-d", "user"]).decode())
    temporary = str(keychain)
    original = [path for path in entries() if path != temporary]
    run(["security", "list-keychains", "-d", "user", "-s", temporary])
    try:
        yield
    finally:
        concurrent = [path for path in entries() if path != temporary and path not in original]
        run(["security", "list-keychains", "-d", "user", "-s", *original, *concurrent])


def validate_acceptance(evidence, output, source, build, allow_physical_waivers=False):
    if evidence.get("source_sha256") != source or evidence.get("build_id") != build:
        raise ReleaseError("Acceptance evidence does not describe this exact source/build")
    result = {"passed_checks": [], "waived_checks": []}
    authorization = evidence.get("waiver_authorization", {})
    for check in ("production_cloudkit", *PHYSICAL_ACCEPTANCE, "ios_ui"):
        entry = evidence.get(check, {})
        path = output / entry.get("evidence_file", "")
        if not path.is_file() or digest(path) != entry.get("sha256"):
            raise ReleaseError(f"Missing or invalid acceptance evidence: {check}")
        if entry.get("passed") is True:
            result["passed_checks"].append(check)
        elif (allow_physical_waivers and check in PHYSICAL_ACCEPTANCE
              and entry.get("waived") is True and entry.get("reason")
              and authorization.get("user_message")
              and check in authorization.get("known_incomplete_checks", [])):
            result["waived_checks"].append(check)
        else:
            raise ReleaseError(f"Acceptance check did not pass: {check}")
    if result["waived_checks"]:
        result["waiver_authorization"] = authorization
    return result


def source_snapshot(root=ROOT):
    paths = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root
    ).split(b"\0")
    # SwiftPM and Xcode keep production resolution/configuration under ignored
    # folders. Capture only those inputs, without scanning build output or user data.
    critical = []
    for package in (root, root / "NeoAnkiCore"):
        critical.extend((package / "Package.resolved", package / ".swiftpm/Package.resolved"))
        critical.extend((package / ".swiftpm/configuration").glob("*.json"))
    critical.extend((root / "Xcode").glob("*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
    critical.extend((root / "Xcode").glob("*.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
    paths.extend(os.fsencode(path.relative_to(root)) for path in critical if path.is_file() or path.is_symlink())
    result = []
    for raw in sorted(set(filter(None, paths))):
        name = os.fsdecode(raw)
        path = root / name
        if path.is_symlink():
            content, mode = os.fsencode(os.readlink(path)), "symlink"
        elif path.is_file():
            content, mode = path.read_bytes(), "executable" if path.stat().st_mode & 0o111 else "file"
        else:
            content, mode = b"", "deleted"
        result.append({"path": name, "kind": mode, "sha256": hashlib.sha256(content).hexdigest()})
    encoded = json.dumps(result, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest(), result


def save_json(path, data):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def raw_es256(der):
    """Convert OpenSSL's short P-256 DER signature to JWT's fixed-width R || S."""
    if len(der) < 8 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ReleaseError("Invalid P-256 signature")
    offset, numbers = 2, []
    for _ in range(2):
        if offset + 2 > len(der) or der[offset] != 2:
            raise ReleaseError("Invalid P-256 integer")
        size = der[offset + 1]
        integer = der[offset + 2:offset + 2 + size]
        if not integer or integer[0] & 0x80 or len(integer) != size:
            raise ReleaseError("Invalid P-256 integer length")
        integer = integer.lstrip(b"\0")
        if len(integer) > 32:
            raise ReleaseError("Invalid P-256 integer width")
        numbers.append(integer.rjust(32, b"\0"))
        offset += size + 2
    if offset != len(der):
        raise ReleaseError("Unexpected P-256 signature bytes")
    return b"".join(numbers)


class AppleAPI:
    def __init__(self, config):
        for key in ("key_id", "issuer_id", "private_key_path"):
            if not config.get(key):
                raise ReleaseError(f"App Store Connect configuration is missing {key}")
        self.config = config
        self.key = Path(config["private_key_path"]).expanduser().resolve()
        if not self.key.is_file():
            raise ReleaseError("The configured App Store Connect private key is missing")

    def token(self):
        now = int(time.time())
        header = {"alg": "ES256", "kid": self.config["key_id"], "typ": "JWT"}
        body = {"iss": self.config["issuer_id"], "iat": now, "exp": now + 600,
                "aud": "appstoreconnect-v1"}
        message = (b64url(json.dumps(header).encode()) + "." + b64url(json.dumps(body).encode())).encode()
        signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(self.key)],
                                input=message, capture_output=True)
        if signed.returncode:
            raise ReleaseError("Could not sign App Store Connect authentication token")
        return message.decode() + "." + b64url(raw_es256(signed.stdout))

    def request(self, path, method="GET", body=None):
        url = urllib.parse.urljoin(API, path)
        # Never forward a bearer token to upload hosts or unexpected next-page URLs.
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com":
            raise ReleaseError("Refusing an unexpected App Store Connect API host")
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, method=method,
                                        headers={"Authorization": "Bearer " + self.token(),
                                                 "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            try:
                codes = [e.get("code", "UNKNOWN") for e in json.loads(error.read()).get("errors", [])]
            except (ValueError, KeyError):
                codes = []
            raise ReleaseError(f"Apple API {method} {parsed.path}: HTTP {error.code}, {', '.join(codes)}") from None

    def list(self, resource, **filters):
        query = urllib.parse.urlencode({"limit": 200, **filters})
        page, result = resource + "?" + query, []
        while page:
            response = self.request(page)
            result.extend(response.get("data", []))
            page = response.get("links", {}).get("next")
        return result

    def app(self):
        apps = self.list("apps", **{"filter[bundleId]": APP_ID})
        if len(apps) != 1:
            raise ReleaseError("Create the NeoAnki2 iOS app record in App Store Connect first")
        if self.config.get("app_id") and self.config["app_id"] != apps[0]["id"]:
            raise ReleaseError("Configured Apple app ID does not match the bundle identifier")
        return apps[0]["id"]

    def bundle_identifier(self, identifier):
        # Apple's identifier filter also returns identifiers with this prefix,
        # including an app's extensions. Select the exact registered identity.
        matches = [item for item in self.list("bundleIds", **{"filter[identifier]": identifier})
                   if item["attributes"]["identifier"] == identifier]
        if len(matches) != 1:
            raise ReleaseError(f"Register the bundle identifier and required capabilities: {identifier}")
        return matches[0]


def validate_store_profile(profile, bundle, cert, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, dt.datetime) or expires.replace(tzinfo=dt.timezone.utc) <= now:
        raise ReleaseError(f"Expired App Store profile for {bundle}")
    ent = profile.get("Entitlements", {})
    if profile.get("TeamIdentifier") != [TEAM] or ent.get("application-identifier") != TEAM + "." + bundle:
        raise ReleaseError(f"App Store profile identity mismatch for {bundle}")
    if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices") or ent.get("get-task-allow") is not False:
        raise ReleaseError(f"Profile for {bundle} is not an App Store distribution profile")
    if cert not in profile.get("DeveloperCertificates", []):
        raise ReleaseError(f"Profile for {bundle} does not include the saved distribution certificate")
    try:
        source = plistlib.loads((ROOT / ("Platforms/iOS/NeoAnki2.entitlements" if bundle == APP_ID
                                        else "Platforms/iOSWidget/NeoAnkiWidget.entitlements")).read_bytes())
        return SIGNER.make_entitlements(source, profile, TEAM, bundle)
    except SIGNER.DeploymentError as error:
        raise ReleaseError(str(error)) from None


@contextlib.contextmanager
def installed_profiles(profiles):
    folder = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    folder.mkdir(parents=True, exist_ok=True)
    added = []
    try:
        for profile, path in profiles.values():
            destination = folder / (profile["UUID"] + ".mobileprovision")
            if destination.exists():
                if destination.read_bytes() != path.read_bytes():
                    raise ReleaseError("An installed provisioning profile conflicts with the release profile")
            else:
                shutil.copy2(path, destination)
                added.append((destination, digest(destination)))
        yield
    finally:
        for path, sha in added:
            if path.exists() and digest(path) == sha:
                path.unlink()


class Workflow:
    def __init__(self, args):
        self.args = args
        self.fingerprint, files = source_snapshot()
        self.output = args.output or ROOT / ".build/ios-release" / self.fingerprint[:16]
        self.output.mkdir(parents=True, exist_ok=True)
        self.receipt = self.output / "release.json"
        self.state = json.loads(self.receipt.read_text()) if self.receipt.exists() else {
            "schema_version": 1, "source_sha256": self.fingerprint,
            "source_revision": run(["git", "rev-parse", "HEAD"]).decode().strip(),
            "bundle_id": APP_ID, "team_id": TEAM, "version": args.version, "build": args.build,
            "phases": {}, "created_at": dt.datetime.now(dt.timezone.utc).isoformat()
        }
        if args.reuse_build_from and not self.receipt.exists():
            previous = reuse_binary_candidate(args.reuse_build_from, files, args.version, args.build)
            self.state.update({key: previous[key] for key in ("build", "build_id", "app_id")})
            self.state["phases"] = {key: previous["phases"][key] for key in ("archive", "export", "upload")}
            self.state["binary_candidate"] = str(args.reuse_build_from)
            self.state["binary_source_sha256"] = binary_source(files)
            self.state["rejected_version_ids"] = previous.get("rejected_version_ids", [])
        if self.state["source_sha256"] != self.fingerprint:
            raise ReleaseError("Source changed; use a new output directory to preserve the existing release")
        if self.state["version"] != args.version or (args.build and self.state["build"] != args.build):
            raise ReleaseError("Version/build changed; use a new output directory")
        save_json(self.output / "source.json", files)
        self.config = json.loads(args.config.read_text()) if args.config.exists() else None
        if self.config and self.config.get("team_id", TEAM) != TEAM:
            raise ReleaseError("Configured team differs from the authorized release team")
        self.api = AppleAPI(self.config) if self.config else None
        self.phase = "preflight"
        self.save()

    def save(self):
        save_json(self.receipt, self.state)

    def mark(self, phase):
        self.phase = phase
        print(f"IOS_RELEASE_PHASE={phase}", flush=True)

    def verify_source(self):
        if source_snapshot()[0] != self.fingerprint:
            raise ReleaseError("Source changed during the release; the candidate is no longer current")

    def require_api(self):
        if not self.api:
            raise ReleaseError(f"Apple authentication is required; configure {self.args.config}")
        app_id = self.api.app()
        if self.state.get("app_id") and self.state["app_id"] != app_id:
            raise ReleaseError("Apple app ID changed")
        self.state["app_id"] = app_id
        self.save()
        return app_id

    def builds(self):
        return self.api.list("builds", **{"filter[app]": self.state["app_id"],
                                         "filter[preReleaseVersion.version]": self.state["version"]})

    def exact_build(self):
        found = [b for b in self.builds() if b["attributes"]["version"] == self.state["build"]]
        if len(found) > 1:
            raise ReleaseError("Multiple Apple builds match this release identity")
        return found[0] if found else None

    def prepare(self):
        self.mark("verify")
        checks = [("fast", [str(ROOT / "Scripts/test-fast.sh")]),
                  ("sync-stress", [str(ROOT / "Scripts/test-sync.sh"), "--stress"]),
                  ("release-tests", ["python3", str(ROOT / "Scripts/test-release-ios.py")]),
                  ("review-runner-tests", ["python3", str(ROOT / "Scripts/test-review-ios-app.py")]),
                  ("screenshot-tests", ["python3", str(ROOT / "Scripts/test-capture-ios-app-store.py")])]
        for name, command in checks:
            saved = self.state["phases"].get(name)
            log = self.output / (name + ".log")
            if saved and log.exists() and saved.get("log_sha256") == digest(log):
                continue
            # The desktop can inherit a Command Line Tools SDK while xcrun
            # selects Xcode's compiler. Use the SDK from that same toolchain.
            environment = os.environ.copy()
            environment["SDKROOT"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).decode().strip()
            run(command, timeout=1800, log=log, env=environment)
            self.verify_source()
            self.state["phases"][name] = {"log_sha256": digest(log), "passed": True}
            self.save()
        if not self.state["build"]:
            if self.api:
                self.require_api()
                numeric = [int(b["attributes"]["version"]) for b in self.builds()
                           if b["attributes"]["version"].isdigit()]
                self.state["build"] = str(max(numeric, default=0) + 1)
            else:
                self.state["build"] = "1"
                self.state["build_requires_remote_check"] = True
            self.save()
        archive = self.output / "NeoAnki2.xcarchive"
        app = archive / "Products/Applications/NeoAnki2.app"
        saved = self.state["phases"].get("archive")
        if saved and app.exists() and digest(app / "NeoAnki2") == saved["executable_sha256"]:
            return
        self.mark("archive")
        if archive.exists():
            raise ReleaseError("Incomplete archive exists; preserve it and use a new output directory")
        run(["xcodebuild", "archive", "-quiet", "-project", str(ROOT / "Xcode/NeoAnkiiOS.xcodeproj"),
             "-scheme", "NeoAnkiiOS", "-configuration", "Release", "-destination", "generic/platform=iOS",
             "-derivedDataPath", str(self.output / "derived-data"), "-archivePath", str(archive),
             "CODE_SIGNING_ALLOWED=NO", "SWIFT_ENABLE_EXPLICIT_MODULES=NO",
             "MARKETING_VERSION=" + self.state["version"], "CURRENT_PROJECT_VERSION=" + self.state["build"]],
            timeout=1800, log=self.output / "archive.log")
        for path, bundle in [(app, APP_ID), (app / "PlugIns/NeoAnki2Widget.appex", WIDGET_ID)]:
            info = plistlib.loads((path / "Info.plist").read_bytes())
            if (info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (
                    bundle, self.state["version"], self.state["build"]):
                raise ReleaseError("Archived app/widget identity does not match the release")
        self.verify_source()
        self.state["phases"]["archive"] = {"executable_sha256": digest(app / "NeoAnki2"),
                                              "xcode": run(["xcodebuild", "-version"]).decode().strip()}
        self.save()

    def profiles(self):
        self.mark("provision")
        cert = run(["openssl", "x509", "-in", str(self.args.signing_dir / "Apple-Distribution.cert.pem"),
                    "-outform", "DER"])
        run(["openssl", "x509", "-in", str(self.args.signing_dir / "Apple-Distribution.cert.pem"),
             "-checkend", "0", "-noout"])
        certificates = self.api.list("certificates", **{"filter[certificateType]": "DISTRIBUTION,IOS_DISTRIBUTION"})
        matches = [c for c in certificates if base64.b64decode(c["attributes"]["certificateContent"]) == cert]
        if len(matches) != 1:
            raise ReleaseError("Saved distribution certificate is not registered with the Apple API team")
        result = {}
        for bundle in (APP_ID, WIDGET_ID):
            path = self.output / (bundle + ".mobileprovision")
            valid = None
            if path.exists():
                profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(path)]))
                validate_store_profile(profile, bundle, cert)
                valid = profile
            else:
                identifier = self.api.bundle_identifier(bundle)
                candidates = self.api.list("profiles", **{"filter[profileType]": "IOS_APP_STORE"})
                for candidate in candidates:
                    raw = base64.b64decode(candidate["attributes"]["profileContent"])
                    with tempfile.NamedTemporaryFile() as temporary:
                        temporary.write(raw)
                        temporary.flush()
                        profile = plistlib.loads(run(["security", "cms", "-D", "-i", temporary.name]))
                    if profile.get("Entitlements", {}).get("application-identifier") != TEAM + "." + bundle:
                        continue
                    try:
                        validate_store_profile(profile, bundle, cert)
                    except ReleaseError:
                        continue
                    path.write_bytes(raw)
                    valid = profile
                    break
                if valid is None:
                    data = {"type": "profiles", "attributes": {
                        "name": "NeoAnki2 App Store " + bundle + " " + self.fingerprint[:8],
                        "profileType": "IOS_APP_STORE"}, "relationships": {
                        "bundleId": {"data": {"type": "bundleIds", "id": identifier["id"]}},
                        "certificates": {"data": [{"type": "certificates", "id": matches[0]["id"]}]}}}
                    response = self.api.request("profiles", "POST", {"data": data})["data"]
                    path.write_bytes(base64.b64decode(response["attributes"]["profileContent"]))
                    valid = plistlib.loads(run(["security", "cms", "-D", "-i", str(path)]))
                    validate_store_profile(valid, bundle, cert)
            result[bundle] = (valid, path)
        return result, cert

    def export(self):
        self.require_api()
        self.prepare()
        if self.state.get("build_requires_remote_check"):
            if self.exact_build():
                raise ReleaseError("Provisional build number already exists in Apple; prepare a new output with --build")
            self.state.pop("build_requires_remote_check", None)
            self.save()
        ipa = self.output / "export/NeoAnki2.ipa"
        saved = self.state["phases"].get("export")
        if saved and ipa.exists() and digest(ipa) == saved["ipa_sha256"]:
            return ipa
        profiles, cert = self.profiles()
        identity = hashlib.sha1(cert).hexdigest().upper()
        archive = self.output / "NeoAnki2.xcarchive"
        signer = SIGNER.Workflow(self.output)
        self.mark("export")
        with signing_archive(archive, self.output) as archive, \
             signer.signing_keychain(self.args.signing_dir) as keychain, \
             export_keychain_search(keychain), installed_profiles(profiles):
            app = archive / "Products/Applications/NeoAnki2.app"
            for framework in sorted((app / "Frameworks").glob("*")):
                signer.run(["codesign", "--force", "--keychain", str(keychain), "--sign", identity,
                            "--timestamp=none", str(framework)])
            for bundle, product in [(WIDGET_ID, app / "PlugIns/NeoAnki2Widget.appex"), (APP_ID, app)]:
                profile, path = profiles[bundle]
                entitlements = validate_store_profile(profile, bundle, cert)
                ent_path = self.output / (bundle + "-entitlements.plist")
                ent_path.write_bytes(plistlib.dumps(entitlements))
                shutil.copy2(path, product / "embedded.mobileprovision")
                signer.run(["codesign", "--force", "--keychain", str(keychain), "--sign", identity,
                            "--entitlements", str(ent_path), "--timestamp=none", str(product)])
                signer.run(["codesign", "--verify", "--strict", str(product)])
            info_path = archive / "Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["ApplicationProperties"].update(SigningIdentity="Apple Distribution", Team=TEAM)
            info_path.write_bytes(plistlib.dumps(info))
            options = {"method": "app-store-connect", "destination": "export", "teamID": TEAM,
                       "signingStyle": "manual", "signingCertificate": identity,
                       "provisioningProfiles": {b: p[0]["UUID"] for b, p in profiles.items()},
                       "manageAppVersionAndBuildNumber": False, "uploadSymbols": True}
            export_options = self.output / "ExportOptions.plist"
            export_options.write_bytes(plistlib.dumps(options))
            run(["xcodebuild", "-exportArchive", "-archivePath", str(archive),
                 "-exportPath", str(ipa.parent), "-exportOptionsPlist", str(export_options)],
                timeout=600, log=self.output / "export.log")
        if not ipa.exists():
            raise ReleaseError("Xcode did not export NeoAnki2.ipa")
        self.verify_source()
        self.state["phases"]["export"] = {"ipa_sha256": digest(ipa), "temporary_signing_cleaned": True}
        self.save()
        return ipa

    def upload(self):
        self.require_api()
        self.mark("upload")
        existing = self.exact_build() if self.state["build"] else None
        saved = self.state["phases"].get("upload")
        if existing:
            if not saved:
                raise ReleaseError("An Apple build already exists without a matching local upload receipt")
            self.state["build_id"] = existing["id"]
            self.save()
            return
        if saved:
            raise ReleaseError("Upload was attempted; inspect Apple processing before retrying to avoid duplicates")
        ipa = self.export()
        self.verify_source()
        environment = os.environ.copy()
        # altool locates AuthKey_<ID>.p8 through this dedicated directory.
        with tempfile.TemporaryDirectory(prefix="neoanki-asc-upload-") as folder:
            key = Path(folder) / ("AuthKey_" + self.config["key_id"] + ".p8")
            shutil.copy2(self.api.key, key)
            key.chmod(0o600)
            environment["API_PRIVATE_KEYS_DIR"] = folder
            auth = ["--api-key", self.config["key_id"], "--api-issuer", self.config["issuer_id"]]
            self.mark("validate-upload")
            run(["xcrun", "altool", "--validate-app", "-f", str(ipa), "-t", "ios", *auth,
                 "--output-format", "json"], timeout=600, log=self.output / "validate-upload.log", env=environment)
            self.mark("upload")
            self.state["phases"]["upload"] = {"status": "attempting", "ipa_sha256": digest(ipa)}
            self.save()
            run(["xcrun", "altool", "--upload-app", "-f", str(ipa), "-t", "ios", *auth,
                 "--output-format", "json"], timeout=1200, log=self.output / "upload.log", env=environment)
        self.state["phases"]["upload"]["status"] = "delivered"
        self.save()

    def status(self):
        self.require_api()
        self.mark("status")
        build = self.exact_build() if self.state["build"] else None
        versions = self.api.list("apps/" + self.state["app_id"] + "/appStoreVersions",
                                 **{"filter[platform]": "IOS", "filter[versionString]": self.state["version"]})
        submissions = self.api.list("reviewSubmissions", **{"filter[app]": self.state["app_id"], "filter[platform]": "IOS"})
        items = {s["id"]: self.api.list("reviewSubmissions/" + s["id"] + "/items", include="appStoreVersion") for s in submissions}
        record_rejections(self.state, versions, submissions, items)
        status = {"build": build, "versions": versions}
        save_json(self.output / "apple-status.json", status)
        if build:
            self.state["build_id"] = build["id"]
            print("IOS_RELEASE_PROCESSING_STATE=" + build["attributes"]["processingState"])
        for version in versions:
            print("IOS_RELEASE_APP_STORE_STATE=" + version["attributes"]["appStoreState"])
        self.save()
        return build, versions

    def internal_review_context(self, build, version):
        """Read the exact Apple assets reviewers must inspect; never write Apple."""
        if not build or build["attributes"]["processingState"] != "VALID":
            raise ReleaseError("Internal review requires Apple's processed, valid build")
        relation = self.api.request("appStoreVersions/" + version["id"] + "/relationships/build").get("data")
        if not relation or relation.get("id") != build["id"]:
            raise ReleaseError("Attach the exact release build before internal review")
        export = self.state["phases"].get("export", {})
        binary_candidate = Path(self.state.get("binary_candidate", self.output))
        if binary_candidate != self.output:
            reuse_binary_candidate(binary_candidate, source_snapshot()[1], self.state["version"], self.state["build"])
        ipa = binary_candidate / "export/NeoAnki2.ipa"
        if not ipa.is_file() or digest(ipa) != export.get("ipa_sha256"):
            raise ReleaseError("Internal review requires the checksummed exported candidate IPA")
        context = {"schema_version": 1, "source_sha256": self.fingerprint,
                   "app_source_sha256": application_source(source_snapshot()[1]),
                   "binary_source_sha256": binary_source(source_snapshot()[1]),
                   "version_id": version["id"], "build_id": build["id"],
                   "version": self.state["version"], "build": self.state["build"],
                   "ipa_sha256": export["ipa_sha256"],
                   "version_attributes": {key: version["attributes"].get(key)
                                          for key in ("versionString", "copyright", "releaseType", "usesIdfa")},
                   "local_listing_sha256": digest(ROOT / "Platforms/iOS/AppStore/en-US.json"),
                   "localizations": [], "screenshots": []}
        localizations = self.api.list("appStoreVersions/" + version["id"] + "/appStoreVersionLocalizations")
        for localization in sorted(localizations, key=lambda item: item["attributes"]["locale"]):
            context["localizations"].append({"id": localization["id"], "attributes": localization["attributes"]})
            sets = self.api.list("appStoreVersionLocalizations/" + localization["id"] + "/appScreenshotSets")
            for screenshot_set in sorted(sets, key=lambda item: item["attributes"]["screenshotDisplayType"]):
                images = self.api.list("appScreenshotSets/" + screenshot_set["id"] + "/appScreenshots")
                if not images:
                    raise ReleaseError("An App Store screenshot set is empty")
                for index, image in enumerate(images):
                    attributes = image["attributes"]
                    if attributes.get("assetDeliveryState", {}).get("state") != "COMPLETE" or not attributes.get("sourceFileChecksum"):
                        raise ReleaseError("An App Store screenshot has not completed processing")
                    context["screenshots"].append({"id": image["id"], "locale": localization["attributes"]["locale"],
                        "display_type": screenshot_set["attributes"]["screenshotDisplayType"], "position": index,
                        "source_checksum": attributes["sourceFileChecksum"], "file_name": attributes.get("fileName"),
                        "image_asset": attributes.get("imageAsset")})
        if not {"APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"} <= {s["display_type"] for s in context["screenshots"]}:
            # Apple also accepts newer large-display aliases for these required families.
            families = {"iphone" if "IPHONE" in s["display_type"] else "ipad" if "IPAD" in s["display_type"] else "other"
                        for s in context["screenshots"]}
            if not {"iphone", "ipad"} <= families:
                raise ReleaseError("Internal review requires complete iPhone and iPad screenshots")
        detail = self.api.request("appStoreVersions/" + version["id"] + "/appStoreReviewDetail").get("data")
        if not detail:
            raise ReleaseError("Internal review requires completed Apple reviewer instructions/contact")
        context["review_detail"] = {"id": detail["id"], "attributes": detail["attributes"]}
        context["app_infos"] = []
        for info in sorted(self.api.list("apps/" + self.state["app_id"] + "/appInfos"), key=lambda item: item["id"]):
            item = {"id": info["id"], "attributes": reviewable_app_info_attributes(info["attributes"]),
                    "categories": {}}
            for category in ("primaryCategory", "secondaryCategory"):
                item["categories"][category] = self.api.request("appInfos/" + info["id"] + "/relationships/" + category).get("data")
            item["localizations"] = sorted(self.api.list("appInfos/" + info["id"] + "/appInfoLocalizations"), key=lambda l: l["id"])
            item["age_rating"] = self.api.request("appInfos/" + info["id"] + "/ageRatingDeclaration").get("data")
            if not item["localizations"] or not item["age_rating"] or not item["categories"]["primaryCategory"]:
                raise ReleaseError("Internal review requires complete name/category/age-rating information")
            context["app_infos"].append(item)
        if not context["app_infos"]:
            raise ReleaseError("Internal review requires Apple's actual app information")
        compliance_path = self.output / "compliance-evidence.json"
        if not compliance_path.is_file():
            raise ReleaseError("Internal review requires a fresh App Store Connect privacy declaration proof")
        compliance = json.loads(compliance_path.read_text())
        observed = dt.datetime.fromisoformat(compliance.get("observed_at", "").replace("Z", "+00:00"))
        if observed.tzinfo is None:
            raise ReleaseError("Privacy proof requires an explicit observation timezone")
        elapsed = dt.datetime.now(dt.timezone.utc) - observed
        if (compliance.get("app_id") != self.state["app_id"]
                or elapsed < dt.timedelta(0) or elapsed > dt.timedelta(hours=24)
                or compliance.get("privacy", {}).get("source") != "App Store Connect"
                or not compliance["privacy"].get("declaration") or not compliance.get("limitations")):
            raise ReleaseError("Privacy proof is stale, lacks actual account provenance, or omits its browser-only limitation")
        checked_evidence(compliance["privacy"].get("evidence"), self.output)
        context["compliance_evidence"] = compliance
        rejection_path = self.args.rejection_evidence
        require_rejection_record(self.state, version["id"], rejection_path)
        if rejection_path.exists():
            rejection = json.loads(rejection_path.read_text())
            if rejection.get("version_id") != version["id"] or not rejection.get("submission_id") or not rejection.get("issues"):
                raise ReleaseError("Apple rejection evidence does not describe this release version")
            ids = set()
            for issue in rejection["issues"]:
                if (not issue.get("id") or issue["id"] in ids or not issue.get("guideline")
                        or not issue.get("message") or not isinstance(issue.get("required_tests"), list)):
                    raise ReleaseError("Apple rejection evidence is incomplete or ambiguous")
                ids.add(issue["id"])
            for evidence in rejection.get("apple_evidence", []):
                checked_evidence(evidence, rejection_path.parent)
            if not rejection.get("apple_evidence"):
                raise ReleaseError("Apple rejection requires its original written message or screenshot evidence")
            context["rejection"] = rejection
        elif version["attributes"]["appStoreState"] in ("REJECTED", "METADATA_REJECTED"):
            raise ReleaseError("Preserve Apple's exact rejection issues before internal review")
        return context

    def review_context(self):
        self.verify_source()
        build, versions = self.status()
        if len(versions) != 1:
            raise ReleaseError("Internal review requires one exact App Store version")
        context = self.internal_review_context(build, versions[0])
        save_json(self.output / "review-context.json", context)
        print("IOS_RELEASE_REVIEW_CONTEXT_SHA256=" + json_digest(context))

    def submit(self):
        self.verify_source()
        if not self.state["phases"].get("upload"):
            raise ReleaseError("Submission requires a matching local upload receipt")
        build, versions = self.status()
        self.mark("submit")
        if not build or build["attributes"]["processingState"] != "VALID":
            raise ReleaseError("Apple has not finished processing a valid release build; resume with submit")
        if len(versions) != 1:
            raise ReleaseError("Complete the version listing, screenshots, privacy, and compliance in App Store Connect")
        version = versions[0]
        attributes = version["attributes"]
        relation = self.api.request("appStoreVersions/" + version["id"] + "/relationships/build").get("data")
        if relation is None or relation["id"] != build["id"]:
            raise ReleaseError("Attach the exact release build to the App Store version before submission")
        if attributes.get("releaseType") != "AFTER_APPROVAL":
            raise ReleaseError("Set the release option to automatically release after approval")
        if attributes["appStoreState"] in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE",
                                            "READY_FOR_SALE", "READY_FOR_DISTRIBUTION"):
            self.state["phases"]["submission"] = {"version_id": version["id"], "state": attributes["appStoreState"]}
            self.save()
            return
        self.mark("internal-review")
        review_path = self.output / "internal-review.json"
        if not review_path.is_file():
            raise ReleaseError("Missing mandatory candidate-bound internal-review.json; run review-context and independent reviews")
        context = self.internal_review_context(build, version)
        review = json.loads(review_path.read_text())
        self.state["phases"]["internal-review"] = validate_internal_review(review, context, self.output)
        save_json(self.output / "submitted-review-context.json", context)
        self.save()
        self.mark("submit")
        evidence_path = self.output / "acceptance.json"
        if not evidence_path.exists():
            raise ReleaseError("Missing acceptance.json: production CloudKit, two-device sync, widgets, reminders, TestFlight install, and UI evidence")
        evidence = json.loads(evidence_path.read_text())
        self.state["phases"]["acceptance"] = validate_acceptance(
            evidence, self.output, self.fingerprint, build["id"], self.args.allow_physical_test_waivers)
        self.save()
        # Reconcile Apple's review submission resources before creating any remote object.
        submissions = self.api.list("reviewSubmissions", **{"filter[app]": self.state["app_id"], "filter[platform]": "IOS"})
        items = {s["id"]: self.api.list("reviewSubmissions/" + s["id"] + "/items", include="appStoreVersion")
                 for s in submissions}
        target, has_item = select_review_submission(submissions, items, version["id"], self.state.get("review_submission_id"))
        if target is None:
            target = self.api.request("reviewSubmissions", "POST", {"data": {"type": "reviewSubmissions",
                "attributes": {"platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": self.state["app_id"]}}}}})["data"]
            self.state["review_submission_id"] = target["id"]
            self.save()
        if not has_item:
            self.api.request("reviewSubmissionItems", "POST", {"data": {"type": "reviewSubmissionItems", "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": target["id"]}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
        self.api.request("reviewSubmissions/" + target["id"], "PATCH", {"data": {
            "type": "reviewSubmissions", "id": target["id"], "attributes": {"submitted": True}}})
        confirmed = self.api.request("reviewSubmissions/" + target["id"])["data"]
        if confirmed["attributes"]["state"] not in ("WAITING_FOR_REVIEW", "IN_REVIEW", "COMPLETE"):
            raise ReleaseError("Apple did not confirm submission for review")
        self.state["phases"]["submission"] = {"id": target["id"], "state": confirmed["attributes"]["state"]}
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", nargs="?", default="prepare", choices=["prepare", "export", "upload", "review-context", "submit", "status", "all"])
    parser.add_argument("--prepare-only", action="store_true", help="alias for the prepare stage; no Apple writes")
    parser.add_argument("--config", type=Path, default=SIGNING / "app-store-connect.json")
    parser.add_argument("--signing-dir", type=Path, default=SIGNING)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--version", default="1.0.0")
    parser.add_argument("--build", help="unused numeric Apple build number")
    parser.add_argument("--reuse-build-from", type=Path,
                        help="retain a verified uploaded binary for metadata/test-only remediation; production inputs must match")
    parser.add_argument("--rejection-evidence", type=Path, default=ROOT / ".build/ios-review-rejection/rejection.json",
                        help="retained exact Apple issues and original message evidence; mandatory after rejection")
    parser.add_argument("--allow-physical-test-waivers", action="store_true",
                        help="accept explicitly documented user-approved physical-test gaps; never marks them passed")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", args.version) or (args.build and not re.fullmatch(r"[1-9]\d{0,3}", args.build)):
        parser.error("Use a numeric marketing version and a build number from 1 to 9999")
    args.config, args.signing_dir = args.config.expanduser().resolve(), args.signing_dir.expanduser().resolve()
    args.rejection_evidence = args.rejection_evidence.expanduser().resolve()
    if args.output:
        args.output = args.output.expanduser().resolve()
    if args.reuse_build_from:
        args.reuse_build_from = args.reuse_build_from.expanduser().resolve()
        if args.stage not in ("status", "review-context", "submit"):
            parser.error("--reuse-build-from is limited to status, review-context, and submit; it never rebuilds or uploads")
    base = ROOT / ".build/ios-release"
    base.mkdir(parents=True, exist_ok=True)
    started, flow = time.monotonic(), None
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    with (base / "workflow.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            flow = Workflow(args)
            stages = ["prepare", "upload", "submit"] if args.stage == "all" else [args.stage]
            if args.prepare_only:
                stages = ["prepare"]
            for stage in stages:
                getattr(flow, stage.replace("-", "_"))()
            state = flow.state["phases"].get("submission", {}).get("state")
            status = ("available" if state in ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION")
                      else "submitted_for_review" if state else stages[-1] + "_complete")
            print("IOS_RELEASE_STATUS=" + status)
            print(f"IOS_RELEASE_RECEIPT={flow.receipt}")
            print(f"IOS_RELEASE_SOURCE_SHA256={flow.fingerprint}")
            print(f"IOS_RELEASE_VERSION={flow.state['version']}")
            print(f"IOS_RELEASE_BUILD={flow.state['build']}")
            print(f"IOS_RELEASE_ELAPSED_SECONDS={time.monotonic() - started:.1f}")
        except (ReleaseError, SIGNER.DeploymentError, OSError, ValueError, KeyError, urllib.error.URLError, KeyboardInterrupt) as error:
            message = "Interrupted" if isinstance(error, KeyboardInterrupt) else str(error)
            print(f"IOS_RELEASE_BLOCKED_PHASE={flow.phase if flow else 'preflight'}", file=sys.stderr)
            print(f"IOS_RELEASE_ERROR={message}", file=sys.stderr)
            if flow:
                print(f"IOS_RELEASE_RECEIPT={flow.receipt}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
