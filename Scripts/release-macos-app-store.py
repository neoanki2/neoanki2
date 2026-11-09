#!/usr/bin/env python3
"""Resumable native Mac App Store distribution under the existing NeoAnki2 listing."""
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
import secrets
import shutil
import signal
import tempfile
import time
import urllib.error

SPEC = importlib.util.spec_from_file_location("ios_store_release", Path(__file__).with_name("release-ios.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
TF_SPEC = importlib.util.spec_from_file_location("mac_testflight", Path(__file__).with_name("validate-macos-testflight.py"))
testflight = importlib.util.module_from_spec(TF_SPEC)
TF_SPEC.loader.exec_module(testflight)
ROOT, SIGNING, TEAM, APP_ID = release.ROOT, release.SIGNING, release.TEAM, release.APP_ID
ReleaseError, run, digest = release.ReleaseError, release.run, release.digest
SCOPES = {
    "product": {"fresh_install", "primary_journey", "macos_layout", "permissions", "imports_exports_sync"},
    "compliance": {"metadata", "screenshots", "privacy", "age_rating", "rejection_remediation"},
}
PRODUCTION_TEST = "MacStoreProductionReviewJourneyTests/testFreshInstallCreateStudyAndPersistence"


def application_source():
    # Includes the actual Store packaging, shared production code and review harness.
    files = release.source_snapshot()[1]
    return release.json_digest([f for f in files if release.production_input(f["path"])
                               or f["path"].startswith(("Packaging/", "UITests/", "Scripts/review-macos-app"))])


def validate_profile(profile, certificate, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    expiry = profile.get("ExpirationDate")
    ent = profile.get("Entitlements", {})
    if (not isinstance(expiry, dt.datetime) or expiry.replace(tzinfo=dt.timezone.utc) <= now
            or profile.get("TeamIdentifier") != [TEAM] or "OSX" not in profile.get("Platform", [])
            or ent.get("com.apple.application-identifier") != TEAM + "." + APP_ID
            or ent.get("com.apple.developer.team-identifier") != TEAM
            or "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices")
            or ent.get("get-task-allow", False) or ent.get("com.apple.security.get-task-allow", False)
            or certificate not in profile.get("DeveloperCertificates", [])):
        raise ReleaseError("Expected an unexpired Mac App Store profile for the saved certificate and shared bundle ID")
    environments = ent.get("com.apple.developer.icloud-container-environment", [])
    environments = [environments] if isinstance(environments, str) else environments
    services = ent.get("com.apple.developer.icloud-services", [])
    if ("iCloud.com.neoanki2.app" not in ent.get("com.apple.developer.icloud-container-identifiers", [])
            or "Production" not in environments
            or ent.get("com.apple.developer.aps-environment") != "production"
            or (services != "*" and "CloudKit" not in services)):
        raise ReleaseError("Mac App Store profile must authorize production CloudKit and push notifications")
    result = plistlib.loads((ROOT / "Packaging/AppStore/NeoAnki2.entitlements").read_bytes())
    result.update({"com.apple.application-identifier": TEAM + "." + APP_ID,
                   "com.apple.developer.team-identifier": TEAM,
                   "com.apple.developer.ubiquity-kvstore-identifier": TEAM + "." + APP_ID})
    kvstore = ent.get("com.apple.developer.ubiquity-kvstore-identifier")
    if kvstore not in (TEAM + ".*", result["com.apple.developer.ubiquity-kvstore-identifier"]):
        raise ReleaseError("Mac App Store profile does not authorize the shared iCloud key-value store")
    return result


def validate_mac_privacy(app):
    path = app / "Contents/Resources/PrivacyInfo.xcprivacy"
    if not path.is_file():
        raise ReleaseError("Mac archive lacks its privacy manifest")
    release.validate_privacy_data(path.read_bytes(), "Mac app", {
        "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
        "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1", "3B52.1"},
    })


def validate_internal_review(review, context, output):
    context_sha = release.json_digest(context)
    if review.get("schema_version") != 1 or review.get("context_sha256") != context_sha:
        raise ReleaseError("Mac internal review is missing or stale")
    evidence = review.get("evidence", {})
    if not isinstance(evidence, dict) or not evidence:
        raise ReleaseError("Mac review requires inspectable evidence")
    paths = {key: release.checked_evidence(ref, output) for key, ref in evidence.items()}
    reviewers = release.object_list(review.get("reviewers", []), "reviewers")
    if (len(reviewers) != 2 or {r.get("role") for r in reviewers} != set(SCOPES)
            or len({r.get("reviewer") for r in reviewers if r.get("reviewer")}) != 2):
        raise ReleaseError("Mac review requires independent product and compliance reviewers")
    for reviewer in reviewers:
        report = json.loads(release.checked_evidence(reviewer.get("report"), output).read_text())
        if (report.get("reviewer") != reviewer["reviewer"] or report.get("role") != reviewer["role"]
                or report.get("context_sha256") != context_sha or report.get("decision") != "approve"
                or report.get("blocking_findings") != []):
            raise ReleaseError("Mac reviewer did not approve this exact candidate without blockers")
        observations = release.object_list(report.get("observations", []), "observations")
        if ({o.get("scope") for o in observations} != SCOPES[reviewer["role"]]
                or any(not release.concrete_observation(o, paths) for o in observations)):
            raise ReleaseError("Mac review lacks substantive observations for every required scope")
    tested, production = set(), False
    for entry in release.object_list(review.get("ui_runs", []), "UI runs"):
        proof_path = release.checked_evidence(entry.get("capture_receipt"), output)
        proof = json.loads(proof_path.read_text())
        result = Path(entry.get("result", ""))
        if (proof.get("app_source_sha256") != context["app_source_sha256"] or not result.is_dir()
                or Path(proof.get("result", "")).resolve() != result.resolve()):
            raise ReleaseError("Mac UI evidence does not describe this candidate")
        actual = json.loads(run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result)]))
        cases = release.read_test_cases(actual.get("testNodes", []))
        if not cases or any(c.get("result") != "Passed" for c in cases):
            raise ReleaseError("Mac UI review contains missing, failed or skipped tests")
        if not any("Mac" in d.get("modelName", "") for d in actual.get("devices", [])):
            raise ReleaseError("Mac UI evidence was not run on a Mac")
        identifiers = {c["nodeIdentifier"].removesuffix("()") for c in cases}
        tested.update(identifiers)
        if entry.get("production") is True:
            if (proof.get("configuration") != "AppStore" or proof.get("optimization") != "-O"
                    or proof.get("launch_arguments") != [] or proof.get("launch_environment") != {}
                    or proof.get("fresh_install") is not True or proof.get("test_fixture_seeded") is not False
                    or PRODUCTION_TEST not in identifiers):
                raise ReleaseError("Mac production review requires an ordinary sandboxed optimized first launch")
            executable = release.checked_evidence(proof.get("executable"), proof_path.parent)
            if not proof.get("testflight_identity"):
                raise ReleaseError("Mac review executable differs from an authenticated Apple TestFlight candidate")
            app = executable.parent.parent.parent
            exported = release.checked_evidence(context.get("mac_exported_executable"), output)
            if digest(exported) != context.get("mac_executable_sha256"):
                raise ReleaseError("Retained Mac distribution executable changed")
            expected = {key: context[key] for key in
                        ("version", "build", "source_revision", "source_sha256", "build_id")}
            identity = testflight.validate_testflight_app(app, exported.parent.parent.parent, expected)
            if proof["testflight_identity"] != identity:
                raise ReleaseError("Mac TestFlight identity differs from the app actually reviewed")
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (
                    APP_ID, context["version"], context["build"]):
                raise ReleaseError("Mac review executable identity differs from the exported candidate")
            test_run = release.checked_evidence(proof.get("xctestrun"), proof_path.parent)
            configuration = plistlib.loads(test_run.read_bytes())
            targets = configuration.get("TestConfigurations", [{}])[0].get("TestTargets", [])
            target = next((t for t in targets if t.get("BlueprintName") == "NeoAnki2UITests"), {})
            if (Path(target.get("UITargetAppPath", "")).resolve() != app.resolve()
                    or target.get("CommandLineArguments", []) != []
                    or target.get("UITargetAppCommandLineArguments", []) != []
                    or target.get("UITargetAppEnvironmentVariables", {}) != {}):
                raise ReleaseError("Mac review xctestrun does not launch the ordinary retained app")
            run(["codesign", "--verify", "--strict", str(app)])
            ent = plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", str(app)]))
            if (ent.get("com.apple.security.app-sandbox") is not True
                    or ent.get("com.apple.application-identifier") != TEAM + "." + APP_ID
                    or ent.get("com.apple.developer.team-identifier") != TEAM
                    or ent.get("com.apple.developer.icloud-container-environment") != "Production"
                    or ent.get("com.apple.security.get-task-allow", False)):
                raise ReleaseError("Mac review app lacks the exact sandboxed production signing identity")
            production = True
    if not production:
        raise ReleaseError("Mac review requires the ordinary AppStore Release journey")
    required = {"production_cloudkit", "sandbox", "macos_ui"}
    acceptance = review.get("acceptance", {})
    for name in required:
        check = acceptance.get(name, {})
        release.checked_evidence(check.get("evidence"), output)
        if check.get("passed") is not True:
            raise ReleaseError("Mac acceptance did not pass: " + name)
    assets = release.object_list(review.get("screenshots", []), "screenshots")
    actual_assets = {(s.get("apple_id"), hashlib.md5(release.checked_evidence(s, output).read_bytes()).hexdigest()) for s in assets}
    expected = {(s["id"], s["source_checksum"].lower()) for s in context["screenshots"]}
    if not expected or actual_assets != expected or len(assets) != len(expected):
        raise ReleaseError("Mac screenshot evidence differs from Apple's actual assets")
    rejection = context.get("rejection")
    if rejection:
        remediation = release.object_list(review.get("remediation", []), "remediation")
        if ({r.get("issue_id") for r in remediation} != {i["id"] for i in rejection["issues"]}
                or any(not release.concrete_observation(r, paths) for r in remediation)
                or not {t for i in rejection["issues"] for t in i["required_tests"]} <= tested):
            raise ReleaseError("Mac review does not remediate every Apple rejection")
    return {"context_sha256": context_sha, "review_sha256": release.json_digest(review),
            "reviewers": [r["reviewer"] for r in reviewers], "passed_ui_tests": sorted(tested)}


class Workflow(release.Workflow):
    platform = "MAC_OS"
    output_root = ".build/macos-app-store-release"
    package_name = "NeoAnki2.pkg"
    package_checksum = "pkg_sha256"
    listing_path = "Packaging/AppStore/en-US.json"

    def mark(self, phase):
        self.phase = phase
        print("MACOS_APP_STORE_PHASE=" + phase, flush=True)

    def prepare(self):
        self.mark("verify")
        environment = os.environ.copy()
        environment["SDKROOT"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).decode().strip()
        for name, command in [("fast", [str(ROOT / "Scripts/test-fast.sh")]),
                              ("release-tests", ["python3", str(ROOT / "Scripts/test-release-macos-app-store.py")])]:
            log = self.output / (name + ".log")
            saved = self.state["phases"].get(name, {})
            if not saved.get("passed") or not log.is_file() or saved.get("log_sha256") != digest(log):
                run(command, timeout=1800, log=log, env=environment)
                self.verify_source()
                self.state["phases"][name] = {"passed": True, "log_sha256": digest(log)}
                self.save()
        if not self.state["build"]:
            self.require_api()
            builds = [int(b["attributes"]["version"]) for b in self.builds() if b["attributes"]["version"].isdigit()]
            self.state["build"] = str(max(builds, default=0) + 1)
            self.save()
        archive = self.output / "NeoAnki2.xcarchive"
        app = archive / "Products/Applications/NeoAnki2.app"
        binary = app / "Contents/MacOS/NeoAnki2"
        saved = self.state["phases"].get("archive", {})
        if binary.is_file() and saved.get("executable_sha256") == digest(binary):
            validate_mac_privacy(app)
            return
        if archive.exists():
            raise ReleaseError("Incomplete Mac archive exists; preserve it and use a new output directory")
        self.mark("archive")
        run(["xcodebuild", "archive", "-quiet", "-project", str(ROOT / "Xcode/NeoAnkiMac.xcodeproj"),
             "-scheme", "NeoAnkiMac", "-configuration", "AppStore", "-destination", "generic/platform=macOS",
             "-derivedDataPath", str(self.output / "derived-data"), "-archivePath", str(archive),
             "CODE_SIGNING_ALLOWED=NO", "MARKETING_VERSION=" + self.state["version"],
             "CURRENT_PROJECT_VERSION=" + self.state["build"]], timeout=1800, log=self.output / "archive.log", env=environment)
        info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        if (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (
                APP_ID, self.state["version"], self.state["build"]):
            raise ReleaseError("Archived Mac app identity does not match the release")
        info["NeoAnkiGitRevision"] = self.state["source_revision"]
        info_path.write_bytes(plistlib.dumps(info))
        if (not info.get("LSApplicationCategoryType") or not info.get("NSHumanReadableCopyright")
                or not (app / "Contents/Resources/PrivacyInfo.xcprivacy").is_file()):
            raise ReleaseError("Mac archive lacks its category, copyright or privacy manifest")
        validate_mac_privacy(app)
        arches = run(["lipo", "-archs", str(binary)]).decode().split()
        if set(arches) != {"arm64", "x86_64"}:
            raise ReleaseError("Mac archive must contain both arm64 and x86_64")
        self.verify_source()
        self.state["phases"]["archive"] = {"executable_sha256": digest(binary), "architectures": arches}
        self.save()

    def profiles(self):
        self.mark("provision")
        cert = run(["openssl", "x509", "-in", str(self.args.signing_dir / "Apple-Distribution.cert.pem"), "-outform", "DER"])
        run(["openssl", "x509", "-in", str(self.args.signing_dir / "Apple-Distribution.cert.pem"), "-checkend", "0", "-noout"])
        certificates = self.api.list("certificates", **{"filter[certificateType]": "DISTRIBUTION,MAC_APP_DISTRIBUTION"})
        matches = [c for c in certificates if base64.b64decode(c["attributes"]["certificateContent"]) == cert]
        if len(matches) != 1:
            raise ReleaseError("Saved Apple Distribution identity is not registered with this Apple team")
        path = self.output / "Mac-AppStore.provisionprofile"
        if path.is_file():
            profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(path)]))
            return validate_profile(profile, cert), path, cert
        for item in self.api.list("profiles", **{"filter[profileType]": "MAC_APP_STORE"}):
            raw = base64.b64decode(item["attributes"]["profileContent"])
            with tempfile.NamedTemporaryFile() as temp:
                temp.write(raw); temp.flush()
                profile = plistlib.loads(run(["security", "cms", "-D", "-i", temp.name]))
            try:
                entitlements = validate_profile(profile, cert)
            except ReleaseError:
                continue
            path.write_bytes(raw)
            return entitlements, path, cert
        identifier = self.api.bundle_identifier(APP_ID)
        item = self.api.request("profiles", "POST", {"data": {"type": "profiles", "attributes": {
            "name": "NeoAnki2 Mac App Store " + self.fingerprint[:8], "profileType": "MAC_APP_STORE"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": identifier["id"]}},
                              "certificates": {"data": [{"type": "certificates", "id": matches[0]["id"]}]}}}})["data"]
        path.write_bytes(base64.b64decode(item["attributes"]["profileContent"]))
        profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(path)]))
        return validate_profile(profile, cert), path, cert

    def export(self):
        self.require_api()
        self.prepare()
        package = self.output / "export" / self.package_name
        saved = self.state["phases"].get("export", {})
        if package.is_file() and saved.get(self.package_checksum) == digest(package):
            return package
        entitlements, profile, certificate = self.profiles()
        installer_cert = self.args.signing_dir / "Mac-Installer-Distribution.cert.pem"
        installer_key = self.args.signing_dir / "Mac-Installer-Distribution.key.pem"
        if not installer_cert.is_file() or not installer_key.is_file():
            raise ReleaseError("Missing Mac Installer Distribution certificate/key in the saved signing directory")
        run(["openssl", "x509", "-in", str(installer_cert), "-checkend", "0", "-noout"])
        installer_der = run(["openssl", "x509", "-in", str(installer_cert), "-outform", "DER"])
        identities = self.api.list("certificates", **{"filter[certificateType]": "MAC_INSTALLER_DISTRIBUTION"})
        if not any(base64.b64decode(c["attributes"]["certificateContent"]) == installer_der for c in identities):
            raise ReleaseError("Mac installer certificate is not registered with this Apple team")
        app = package.parent / "NeoAnki2.app"
        if app.exists() or package.exists():
            raise ReleaseError("Incomplete Mac export exists; preserve it and use a new output directory")
        app.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(self.output / "NeoAnki2.xcarchive/Products/Applications/NeoAnki2.app", app)
        signer = release.SIGNER.Workflow(self.output)
        ent_path = self.output / "store-entitlements.plist"
        ent_path.write_bytes(plistlib.dumps(entitlements))
        self.mark("export")
        with signer.signing_keychain(self.args.signing_dir) as keychain:
            # Installer material is imported only into this disposable Keychain.
            with tempfile.TemporaryDirectory(prefix="neoanki-store-installer-") as folder:
                password = secrets.token_hex(32)
                password_file = Path(folder) / "password"
                password_file.write_text(password); password_file.chmod(0o600)
                p12 = Path(folder) / "installer.p12"
                run(["openssl", "pkcs12", "-export", "-inkey", str(installer_key), "-in", str(installer_cert),
                     "-out", str(p12), "-passout", "file:" + str(password_file), "-passin", "pass:"])
                signer.run(["security", "import", str(p12), "-k", str(keychain), "-P", password,
                            "-T", "/usr/bin/productbuild"])
                signer.run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k",
                            signer.passwords[-1], str(keychain)])
            shutil.copy2(profile, app / "Contents/embedded.provisionprofile")
            identity = hashlib.sha1(certificate).hexdigest().upper()
            run(["codesign", "--force", "--keychain", str(keychain), "--sign", identity, "--timestamp",
                 "--options", "runtime", "--entitlements", str(ent_path), str(app)])
            run(["codesign", "--verify", "--strict", str(app)])
            actual = plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", str(app)]))
            if any(actual.get(k) != v for k, v in entitlements.items()):
                raise ReleaseError("Signed Mac app entitlements differ from the validated profile")
            run(["productbuild", "--component", str(app), "/Applications", "--sign",
                 hashlib.sha1(installer_der).hexdigest().upper(), "--keychain", str(keychain), str(package)],
                timeout=300, log=self.output / "productbuild.log")
        run(["pkgutil", "--check-signature", str(package)], log=self.output / "package-signature.log")
        self.verify_source()
        self.state["phases"]["export"] = {self.package_checksum: digest(package),
            "executable_sha256": digest(app / "Contents/MacOS/NeoAnki2"), "temporary_signing_cleaned": True}
        self.save()
        return package

    def upload(self):
        self.require_api()
        existing = self.exact_build() if self.state["build"] else None
        saved = self.state["phases"].get("upload")
        if existing:
            if not saved:
                raise ReleaseError("Apple build exists without a matching local upload receipt")
            self.state["build_id"] = existing["id"]; self.save(); return
        if saved:
            raise ReleaseError("Mac upload was attempted; inspect Apple processing before any retry")
        package = self.export()
        environment = os.environ.copy()
        with tempfile.TemporaryDirectory(prefix="neoanki-mac-store-upload-") as folder:
            key = Path(folder) / ("AuthKey_" + self.config["key_id"] + ".p8")
            shutil.copy2(self.api.key, key); key.chmod(0o600)
            environment["API_PRIVATE_KEYS_DIR"] = folder
            auth = ["--api-key", self.config["key_id"], "--api-issuer", self.config["issuer_id"]]
            self.mark("validate-upload")
            run(["xcrun", "altool", "--validate-app", "-f", str(package), "-t", "macos", *auth,
                 "--output-format", "json"], timeout=600, log=self.output / "validate-upload.log", env=environment)
            self.verify_source()
            self.state["phases"]["upload"] = {"status": "attempting", self.package_checksum: digest(package)}
            self.save(); self.mark("upload")
            run(["xcrun", "altool", "--upload-app", "-f", str(package), "-t", "macos", *auth,
                 "--output-format", "json"], timeout=1200, log=self.output / "upload.log", env=environment)
        self.state["phases"]["upload"]["status"] = "delivered"; self.save()

    def internal_review_context(self, build, version):
        context = super().internal_review_context(build, version)
        executable = self.output / "export/NeoAnki2.app/Contents/MacOS/NeoAnki2"
        expected = self.state["phases"]["export"].get("executable_sha256")
        if not executable.is_file() or digest(executable) != expected:
            raise ReleaseError("Retained Mac executable differs from the exported candidate")
        context.update(platform=self.platform, app_source_sha256=application_source(),
                       binary_source_sha256=application_source(), mac_executable_sha256=expected,
                       source_revision=self.state["source_revision"],
                       mac_exported_executable={"path": str(executable), "sha256": expected})
        return context

    def validate_review(self, review, context):
        return validate_internal_review(review, context, self.output)

    def validate_release_acceptance(self, evidence, build):
        if evidence.get("source_sha256") != self.fingerprint or evidence.get("build_id") != build:
            raise ReleaseError("Mac acceptance does not describe this source/build")
        for name in ("production_cloudkit", "sandbox", "macos_ui"):
            item = evidence.get(name, {})
            release.checked_evidence({"path": item.get("evidence_file"), "sha256": item.get("sha256")}, self.output)
            if item.get("passed") is not True:
                raise ReleaseError("Mac acceptance did not pass: " + name)
        return {"passed_checks": ["production_cloudkit", "sandbox", "macos_ui"], "waived_checks": []}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", nargs="?", default="prepare", choices=["prepare", "export", "upload", "review-context", "submit", "status"])
    parser.add_argument("--config", type=Path, default=SIGNING / "app-store-connect.json")
    parser.add_argument("--signing-dir", type=Path, default=SIGNING)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--version", default="1.0.1")
    parser.add_argument("--build")
    parser.add_argument("--rejection-evidence", type=Path, default=ROOT / ".build/macos-review-rejection/rejection.json")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", args.version) or (args.build and not re.fullmatch(r"[1-9]\d{0,3}", args.build)):
        parser.error("Use a numeric marketing version and a build number from 1 to 9999")
    args.config, args.signing_dir = args.config.expanduser().resolve(), args.signing_dir.expanduser().resolve()
    args.rejection_evidence = args.rejection_evidence.expanduser().resolve()
    args.output = args.output.expanduser().resolve() if args.output else None
    args.reuse_build_from, args.allow_physical_test_waivers = None, False
    base = ROOT / Workflow.output_root
    base.mkdir(parents=True, exist_ok=True)
    started, flow = time.monotonic(), None
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    with (base / "workflow.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            flow = Workflow(args)
            getattr(flow, args.stage.replace("-", "_"))()
            state = flow.state["phases"].get("submission", {}).get("state")
            status = ("available" if state in ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION") else "submitted_for_review" if state else args.stage + "_complete")
            for key, value in {"STATUS": status, "RECEIPT": flow.receipt, "SOURCE_SHA256": flow.fingerprint,
                               "VERSION": flow.state["version"], "BUILD": flow.state["build"],
                               "ELAPSED_SECONDS": f"{time.monotonic() - started:.1f}"}.items():
                print(f"MACOS_APP_STORE_{key}={value}")
        except (ReleaseError, RuntimeError, release.SIGNER.DeploymentError, OSError, ValueError, KeyError, urllib.error.URLError, KeyboardInterrupt) as error:
            print("MACOS_APP_STORE_BLOCKED_PHASE=" + (flow.phase if flow else "preflight"))
            print("MACOS_APP_STORE_ERROR=" + ("Interrupted" if isinstance(error, KeyboardInterrupt) else str(error)))
            if flow: print("MACOS_APP_STORE_RECEIPT=" + str(flow.receipt))
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
