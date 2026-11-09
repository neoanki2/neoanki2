#!/usr/bin/env python3
"""Native Mac distribution identity, platform isolation and fail-closed review tests."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import subprocess
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("mac_store", Path(__file__).with_name("release-macos-app-store.py"))
mac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mac)


class MacStoreTests(unittest.TestCase):
    def profile(self):
        return {"ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1),
                "TeamIdentifier": [mac.TEAM], "Platform": ["OSX"], "DeveloperCertificates": [b"certificate"],
                "Entitlements": {"com.apple.application-identifier": mac.TEAM + "." + mac.APP_ID,
                    "com.apple.developer.team-identifier": mac.TEAM,
                    "com.apple.developer.icloud-container-identifiers": ["iCloud.com.neoanki2.app"],
                    "com.apple.developer.icloud-container-environment": "Production",
                    "com.apple.developer.icloud-services": ["CloudKit"],
                    "com.apple.developer.aps-environment": "production",
                    "com.apple.developer.ubiquity-kvstore-identifier": mac.TEAM + ".*"}}

    def test_actual_mac_bundle_requires_selected_file_metadata_reason(self):
        data = plistlib.loads((mac.ROOT / "Packaging/AppStore/PrivacyInfo.xcprivacy").read_bytes())
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "NeoAnki2.app"
            path = app / "Contents/Resources/PrivacyInfo.xcprivacy"
            path.parent.mkdir(parents=True)
            old = plistlib.loads(plistlib.dumps(data))
            for category in old["NSPrivacyAccessedAPITypes"]:
                if category["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryFileTimestamp":
                    category["NSPrivacyAccessedAPITypeReasons"] = ["C617.1"]
            path.write_bytes(plistlib.dumps(old))
            with self.assertRaisesRegex(mac.ReleaseError, "FileTimestamp"):
                mac.validate_mac_privacy(app)
            path.write_bytes(plistlib.dumps(data))
            mac.validate_mac_privacy(app)

    def test_store_profile_produces_sandboxed_shared_identity(self):
        ent = mac.validate_profile(self.profile(), b"certificate")
        self.assertTrue(ent["com.apple.security.app-sandbox"])
        self.assertTrue(ent["com.apple.security.files.user-selected.read-write"])
        self.assertEqual(ent["com.apple.application-identifier"], mac.TEAM + ".com.neoanki2.ios")

    def test_apple_mac_profile_wildcards_are_restricted_to_production_in_signature(self):
        profile = self.profile()
        profile["Entitlements"].update({"com.apple.developer.icloud-services": "*",
            "com.apple.developer.icloud-container-environment": ["Production", "Development"]})
        ent = mac.validate_profile(profile, b"certificate")
        self.assertEqual(ent["com.apple.developer.icloud-services"], ["CloudKit"])
        self.assertEqual(ent["com.apple.developer.icloud-container-environment"], "Production")

    def test_wrong_channel_identity_or_signing_material_is_rejected(self):
        for mutate in [lambda p: p.update(ProvisionsAllDevices=True),
                       lambda p: p.update(ProvisionedDevices=["device"]),
                       lambda p: p.update(Platform=["iOS"]),
                       lambda p: p.update(DeveloperCertificates=[b"other"]),
                       lambda p: p.update(ExpirationDate=dt.datetime(2000, 1, 1)),
                       lambda p: p["Entitlements"].update({"get-task-allow": True}),
                       lambda p: p["Entitlements"].update({"com.apple.application-identifier": mac.TEAM + ".com.neoanki2.app"}),
                       lambda p: p["Entitlements"].update({"com.apple.developer.icloud-container-environment": "Development"})]:
            with self.subTest(mutate=mutate):
                profile = self.profile(); mutate(profile)
                with self.assertRaises(mac.ReleaseError): mac.validate_profile(profile, b"certificate")

    def test_ios_and_mac_build_lookup_are_isolated(self):
        for cls, platform in [(mac.release.Workflow, "IOS"), (mac.Workflow, "MAC_OS")]:
            flow = object.__new__(cls)
            flow.api = Mock(); flow.api.list.return_value = []
            flow.state = {"app_id": "same-app", "version": "1.0.1"}
            flow.builds()
            self.assertEqual(flow.api.list.call_args.kwargs["filter[preReleaseVersion.platform]"], platform)

    def test_store_configuration_does_not_change_homebrew_identity(self):
        root = mac.ROOT
        brew = plistlib.loads((root / "Packaging/Info.plist").read_bytes())
        store = plistlib.loads((root / "Packaging/AppStore/Info.plist").read_bytes())
        self.assertEqual(brew["CFBundleIdentifier"], "com.neoanki2.app")
        self.assertEqual(store["CFBundleIdentifier"], "$(PRODUCT_BUNDLE_IDENTIFIER)")
        self.assertEqual(store["LSApplicationCategoryType"], "public.app-category.education")
        self.assertTrue(store["NSHumanReadableCopyright"])

    def test_store_configuration_is_selectable_for_project_and_target(self):
        project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-",
            str(mac.ROOT / "Xcode/NeoAnkiMac.xcodeproj/project.pbxproj")]))
        objects = project["objects"]
        for key in ("A10000000000000000000005", "A10000000000000000000008"):
            names = {objects[ref]["name"] for ref in objects[key]["buildConfigurations"]}
            self.assertIn("AppStore", names)

    def test_store_packaging_changes_invalidate_review_source(self):
        files = [{"path": "Packaging/AppStore/NeoAnki2.entitlements", "sha256": "before"}]
        with patch.object(mac.release, "source_snapshot", return_value=("source", files)):
            before = mac.application_source()
            files[0]["sha256"] = "after"
            self.assertNotEqual(mac.application_source(), before)

    def test_review_rejects_stale_and_bare_pass_claims(self):
        with tempfile.TemporaryDirectory() as folder:
            for review in [{"passed": True}, {"schema_version": 1, "context_sha256": mac.release.json_digest({})}]:
                with self.assertRaises(mac.ReleaseError): mac.validate_internal_review(review, {}, Path(folder))

    def test_same_source_different_candidate_executable_cannot_reuse_review(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary = root / "app/Contents/MacOS/NeoAnki2"
            binary.parent.mkdir(parents=True); binary.write_bytes(b"candidate-one")
            result = root / "result.xcresult"; result.mkdir()
            context = {"app_source_sha256": "same-source", "mac_executable_sha256": "different-binary",
                       "version": "1.0.1", "build": "2"}
            proof = {"app_source_sha256": "same-source", "result": str(result), "configuration": "AppStore",
                     "optimization": "-O", "launch_arguments": [], "launch_environment": {},
                     "fresh_install": True, "test_fixture_seeded": False,
                     "executable": {"path": str(binary), "sha256": mac.digest(binary)}}
            receipt = root / "proof.json"; receipt.write_text(json.dumps(proof))
            ref = {"path": str(receipt), "sha256": mac.digest(receipt)}
            review = {"schema_version": 1, "context_sha256": mac.release.json_digest(context),
                      "evidence": {"proof": ref}, "reviewers": [],
                      "ui_runs": [{"production": True, "result": str(result), "capture_receipt": ref}]}
            for role, scopes in mac.SCOPES.items():
                report = root / (role + ".json")
                report.write_text(json.dumps({"reviewer": role, "role": role, "context_sha256": review["context_sha256"],
                    "decision": "approve", "blocking_findings": [], "observations": [
                        {"scope": scope, "detail": "Synthetic reviewer fixture binds this test to retained evidence.",
                         "evidence_ids": ["proof"]} for scope in scopes]}))
                review["reviewers"].append({"reviewer": role, "role": role,
                    "report": {"path": str(report), "sha256": mac.digest(report)}})
            actual = {"devices": [{"modelName": "MacBook Pro"}], "testNodes": [
                {"nodeType": "Test Case", "nodeIdentifier": mac.PRODUCTION_TEST + "()", "result": "Passed"}]}
            with patch.object(mac, "run", return_value=json.dumps(actual).encode()):
                with self.assertRaisesRegex(mac.ReleaseError, "executable differs"):
                    mac.validate_internal_review(review, context, root)

    def test_mac_acceptance_cannot_waive_sandbox_or_ui(self):
        with tempfile.TemporaryDirectory() as folder:
            flow = object.__new__(mac.Workflow)
            flow.fingerprint, flow.output = "source", Path(folder)
            proof = Path(folder) / "evidence.json"; proof.write_text("actual checks")
            ref = {"evidence_file": proof.name, "sha256": mac.digest(proof), "passed": True}
            evidence = {"source_sha256": "source", "build_id": "build",
                        **{key: dict(ref) for key in ("production_cloudkit", "sandbox", "macos_ui")}}
            self.assertEqual(len(flow.validate_release_acceptance(evidence, "build")["passed_checks"]), 3)
            evidence["sandbox"].update(passed=False, waived=True)
            with self.assertRaises(mac.ReleaseError): flow.validate_release_acceptance(evidence, "build")


if __name__ == "__main__": unittest.main()
