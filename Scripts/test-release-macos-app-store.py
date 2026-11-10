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
from types import SimpleNamespace
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


class MacBinaryReuseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="neoanki-mac-reuse-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.candidate = self.root / "original"
        self.view = self.root / "review-view"
        self.privacy = (mac.ROOT / "Packaging/AppStore/PrivacyInfo.xcprivacy").read_bytes()
        self.files = [
            {"path": "Sources/App.swift", "kind": "file", "sha256": "original-code"},
            {"path": "Packaging/AppStore/PrivacyInfo.xcprivacy", "kind": "file", "sha256": mac.hashlib.sha256(self.privacy).hexdigest()},
            {"path": "Packaging/NeoAnki2.icns", "kind": "file", "sha256": mac.hashlib.sha256(b"icon").hexdigest()},
            {"path": "Packaging/AppStore/NeoAnki2.entitlements", "kind": "file", "sha256": "production-entitlements"},
            {"path": "Packaging/AppStore/Info.plist", "kind": "file", "sha256": "store-info"},
            {"path": "Packaging/AppStore/en-US.json", "kind": "file", "sha256": "old-listing"},
            {"path": "UITests/Journey.swift", "kind": "file", "sha256": "old-test"},
            {"path": "Scripts/review-macos-app.py", "kind": "file", "sha256": "old-helper"},
        ]
        self.archive_app = self.candidate / "NeoAnki2.xcarchive/Products/Applications/NeoAnki2.app"
        self.export_app = self.candidate / "export/NeoAnki2.app"
        info = {"CFBundleIdentifier": mac.APP_ID, "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "2",
                "NeoAnkiGitRevision": "a" * 40}
        for app in (self.archive_app, self.export_app):
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            (app / "Contents/MacOS/NeoAnki2").write_bytes(b"actual executable")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            (app / "Contents/Resources/PrivacyInfo.xcprivacy").write_bytes(self.privacy)
            (app / "Contents/Resources/NeoAnki2.icns").write_bytes(b"icon")
        self.package = self.candidate / "export/NeoAnki2.pkg"
        self.package.write_bytes(b"uploaded signed package")
        self.state = {"schema_version": 1, "source_sha256": mac.release.json_digest(self.files), "source_revision": "a" * 40,
                      "version": "1.0.1", "build": "2", "app_id": "6818741196", "bundle_id": mac.APP_ID, "team_id": mac.TEAM,
                      "build_id": "c272f07d-1863-4a30-812c-52079678617f", "phases": {
                          "archive": {"executable_sha256": mac.digest(self.archive_app / "Contents/MacOS/NeoAnki2")},
                          "export": {"executable_sha256": mac.digest(self.export_app / "Contents/MacOS/NeoAnki2"), "pkg_sha256": mac.digest(self.package)},
                          "upload": {"status": "delivered", "pkg_sha256": mac.digest(self.package)},
                          "internal-review": {"must-not-copy": True}, "submission": {"must-not-copy": True}}}
        (self.candidate / "source.json").write_text(json.dumps(self.files))
        (self.candidate / "release.json").write_text(json.dumps(self.state))
        self.ent = dict(mac.testflight.REQUIRED_ENTITLEMENTS)
        def run(argv, **kwargs):
            return plistlib.dumps(self.ent) if "--entitlements" in argv else b""
        self.patcher = patch.object(mac, "run", side_effect=run)
        self.patcher.start(); self.addCleanup(self.patcher.stop)

    def changes(self, path):
        return [f | {"sha256": "changed"} if f["path"] == path else f for f in self.files]

    def test_metadata_and_test_helper_only_changes_retain_original_build(self):
        for path in ("Packaging/AppStore/en-US.json", "UITests/Journey.swift", "Scripts/review-macos-app.py"):
            with self.subTest(path=path):
                self.assertEqual(mac.reuse_binary_candidate(self.candidate, self.changes(path), "1.0.1", "2"), self.state)

    def test_every_shipping_packaging_code_and_project_change_rejects_reuse(self):
        for path in ("Sources/App.swift", "Packaging/AppStore/PrivacyInfo.xcprivacy", "Packaging/NeoAnki2.icns",
                     "Packaging/AppStore/NeoAnki2.entitlements", "Packaging/AppStore/Info.plist"):
            with self.subTest(path=path), self.assertRaisesRegex(mac.ReleaseError, "production inputs changed"):
                mac.reuse_binary_candidate(self.candidate, self.changes(path), "1.0.1", "2")
        for path in ("NeoAnkiCore/Sources/New.swift", "Xcode/NeoAnkiMac.xcodeproj/project.pbxproj", "Packaging/new-shipping.json"):
            with self.subTest(added=path), self.assertRaisesRegex(mac.ReleaseError, "production inputs changed"):
                mac.reuse_binary_candidate(self.candidate, self.files + [{"path": path, "kind": "file", "sha256": "new"}], "1.0.1", "2")

    def test_old_privacy_resources_and_unsigned_or_debug_exports_cannot_reuse(self):
        privacy = self.export_app / "Contents/Resources/PrivacyInfo.xcprivacy"
        manifest = plistlib.loads(self.privacy)
        manifest["NSPrivacyAccessedAPITypes"] = []
        privacy.write_bytes(plistlib.dumps(manifest))
        with self.assertRaisesRegex(mac.ReleaseError, "privacy manifest"):
            mac.reuse_binary_candidate(self.candidate, self.files, "1.0.1", "2")
        privacy.write_bytes(self.privacy)
        with patch.object(mac, "run", side_effect=mac.ReleaseError("signature invalid")):
            with self.assertRaisesRegex(mac.ReleaseError, "signature invalid"):
                mac.reuse_binary_candidate(self.candidate, self.files, "1.0.1", "2")
        self.ent["get-task-allow"] = True
        with self.assertRaisesRegex(mac.ReleaseError, "Production sandbox"):
            mac.reuse_binary_candidate(self.candidate, self.files, "1.0.1", "2")

    def test_missing_or_mutated_upload_package_export_and_source_proofs_reject(self):
        original = self.package.read_bytes()
        self.package.write_bytes(b"tampered package")
        with self.assertRaisesRegex(mac.ReleaseError, "verified archive/export/upload"):
            mac.reuse_binary_candidate(self.candidate, self.files, "1.0.1", "2")
        self.package.write_bytes(original)
        binary = self.export_app / "Contents/MacOS/NeoAnki2"
        binary.write_bytes(b"different executable")
        with self.assertRaisesRegex(mac.ReleaseError, "verified archive/export/upload"):
            mac.reuse_binary_candidate(self.candidate, self.files, "1.0.1", "2")
        binary.write_bytes(b"actual executable")
        (self.candidate / "source.json").write_text(json.dumps(self.files[:-1]))
        with self.assertRaisesRegex(mac.ReleaseError, "production inputs changed"):
            mac.reuse_binary_candidate(self.candidate, self.files, "1.0.1", "2")

    def test_wrong_version_build_team_source_stamp_or_apple_identity_rejects(self):
        with self.assertRaisesRegex(mac.ReleaseError, "version/build"):
            mac.reuse_binary_candidate(self.candidate, self.files, "1.0.1", "1")
        info = self.export_app / "Contents/Info.plist"
        data = plistlib.loads(info.read_bytes()); data["NeoAnkiGitRevision"] = "b" * 40
        info.write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(mac.ReleaseError, "original binary identity"):
            mac.reuse_binary_candidate(self.candidate, self.files, "1.0.1", "2")

    def args(self, stage="status", reuse=True):
        return SimpleNamespace(output=self.view, reuse_build_from=self.candidate if reuse else None,
                               version="1.0.1", build="2", stage=stage, config=self.root / "no-config.json")

    def workflow(self, args=None):
        current = self.changes("Scripts/review-macos-app.py")
        with patch.object(mac.release, "source_snapshot", return_value=(mac.release.json_digest(current), current)), \
             patch.object(mac.release, "run", return_value=("b" * 40).encode()):
            return mac.Workflow(args or self.args())

    def test_view_preserves_original_paths_identity_and_omits_old_approvals(self):
        original = (self.candidate / "release.json").read_bytes()
        flow = self.workflow()
        self.assertEqual(flow.state["binary_candidate"], str(self.candidate))
        self.assertEqual(flow.state["binary_snapshot_sha256"], self.state["source_sha256"])
        self.assertEqual(flow.state["binary_source_revision"], "a" * 40)
        self.assertNotEqual(flow.state["source_sha256"], self.state["source_sha256"])
        self.assertEqual(flow.state["source_revision"], "b" * 40)
        self.assertEqual(set(flow.state["phases"]), {"archive", "export", "upload"})
        self.assertEqual((self.candidate / "release.json").read_bytes(), original)
        self.assertEqual(mac.testflight_expected_identity(flow.state)["source_sha256"], self.state["source_sha256"])
        resumed = self.workflow(self.args(reuse=False))
        self.assertEqual(resumed.state["binary_source_revision"], "a" * 40)

    def test_view_and_explicit_reuse_cannot_prepare_export_or_upload(self):
        for stage in ("prepare", "export", "upload"):
            with self.subTest(stage=stage), self.assertRaisesRegex(mac.ReleaseError, "limited"):
                self.workflow(self.args(stage=stage))
        flow = self.workflow()
        for stage in ("prepare", "export", "upload"):
            with self.subTest(stage=stage), self.assertRaisesRegex(mac.ReleaseError, "cannot"):
                getattr(flow, stage)()
            with self.subTest(resume=stage), self.assertRaisesRegex(mac.ReleaseError, "cannot"):
                self.workflow(self.args(stage=stage, reuse=False))

    def test_resumed_view_rejects_modified_artifact_receipts_and_binary_identity(self):
        flow = self.workflow()
        original = json.loads(flow.receipt.read_text())
        changed = json.loads(json.dumps(original))
        changed["phases"]["upload"]["pkg_sha256"] = "different-upload"
        flow.receipt.write_text(json.dumps(changed))
        with self.assertRaisesRegex(mac.ReleaseError, "artifact receipts"):
            self.workflow(self.args(reuse=False))
        changed = original | {"binary_source_revision": "c" * 40}
        flow.receipt.write_text(json.dumps(changed))
        with self.assertRaisesRegex(mac.ReleaseError, "original binary source identity"):
            self.workflow(self.args(reuse=False))

    def test_context_binds_current_qa_source_but_original_export_and_binary_stamp(self):
        flow = self.workflow()
        current = self.changes("Scripts/review-macos-app.py")
        with patch.object(mac.release.Workflow, "internal_review_context", return_value={"source_sha256": flow.fingerprint}), \
             patch.object(mac.release, "source_snapshot", return_value=(flow.fingerprint, current)), \
             patch.object(mac, "application_source", return_value="current-qa-app-source"):
            context = flow.internal_review_context({"id": self.state["build_id"]}, {})
            with self.assertRaisesRegex(mac.ReleaseError, "Apple build differs"):
                flow.internal_review_context({"id": "different-apple-build"}, {})
        self.assertEqual(context["mac_exported_executable"]["path"], str(self.export_app / "Contents/MacOS/NeoAnki2"))
        self.assertEqual(context["source_sha256"], flow.fingerprint)
        self.assertEqual(context["source_revision"], "b" * 40)
        self.assertEqual(context["binary_snapshot_sha256"], self.state["source_sha256"])
        self.assertEqual(context["binary_source_revision"], "a" * 40)
        self.assertEqual(context["app_source_sha256"], "current-qa-app-source")

    def test_testflight_identity_maps_original_or_unreused_record_without_other_metadata(self):
        expected = mac.testflight_expected_identity(self.state)
        self.assertEqual(expected["source_revision"], "a" * 40)
        self.assertEqual(expected["source_sha256"], self.state["source_sha256"])
        self.assertEqual(expected["phases"], {"export": {"executable_sha256": self.state["phases"]["export"]["executable_sha256"]}})
        with self.assertRaisesRegex(mac.ReleaseError, "Incomplete original"):
            mac.testflight_expected_identity(self.state | {"binary_source_revision": "a" * 40})


if __name__ == "__main__": unittest.main()
