#!/usr/bin/env python3
"""Safety and resume invariants for the App Store release workflow."""
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("ios_release", Path(__file__).with_name("release-ios.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_resolved_apple_state_preserves_review_but_age_rating_change_invalidates_it(self):
        with tempfile.TemporaryDirectory() as folder:
            output, context, review, _, xcrun = self.review_fixture(folder)
            attributes = {"state": "REJECTED", "appStoreAgeRating": "FOUR_PLUS"}
            context["app_infos"] = [{"id": "info", "attributes": release.reviewable_app_info_attributes(attributes)}]
            review["context_sha256"] = release.json_digest(context)
            for reviewer in review["reviewers"]:
                report_path = output / reviewer["report"]["path"]
                report = json.loads(report_path.read_text())
                report["context_sha256"] = review["context_sha256"]
                report_path.write_text(json.dumps(report))
                reviewer["report"]["sha256"] = release.digest(report_path)
            with patch.object(release, "run", side_effect=xcrun):
                for state in ("READY_FOR_REVIEW", "WAITING_FOR_REVIEW"):
                    context["app_infos"][0]["attributes"] = release.reviewable_app_info_attributes(attributes | {"state": state})
                    release.validate_internal_review(review, context, output)
                context["app_infos"][0]["attributes"] = release.reviewable_app_info_attributes(
                    attributes | {"state": "READY_FOR_REVIEW", "appStoreAgeRating": "TWELVE_PLUS"})
                with self.assertRaisesRegex(release.ReleaseError, "stale"):
                    release.validate_internal_review(review, context, output)

    def review_fixture(self, folder):
        output = Path(folder)
        output.mkdir(parents=True, exist_ok=True)
        pixel = output / "capture.png"
        pixel.write_bytes(b"captured image fixture")
        context = {"app_source_sha256": "application-and-harness", "source_sha256": "exact-source",
                   "build_id": "exact-build", "localizations": [{"description": "Reviewed listing"}],
                   "screenshots": [{"id": "apple-image", "source_checksum": hashlib.md5(pixel.read_bytes()).hexdigest()}]}
        ref = {"path": pixel.name, "sha256": release.digest(pixel)}
        review = {"schema_version": 1, "context_sha256": release.json_digest(context),
                  "evidence": {"actual-pixels": ref}, "reviewers": [], "ui_runs": [],
                  "screenshots": [ref | {"apple_id": "apple-image"}]}
        for role, scopes in release.INTERNAL_REVIEW_SCOPES.items():
            report = output / (role + ".json")
            report.write_text(json.dumps({"reviewer": role + "-agent", "role": role,
                "context_sha256": release.json_digest(context), "decision": "approve", "blocking_findings": [],
                "observations": [{"scope": scope, "detail": "Inspected the exact candidate and retained concrete UI evidence for this scope.",
                                  "evidence_ids": ["actual-pixels"]} for scope in scopes]}))
            review["reviewers"].append({"reviewer": role + "-agent", "role": role,
                                       "report": {"path": report.name, "sha256": release.digest(report)}})
        results = {}
        for family, model in [("iphone", "iPhone 17"), ("ipad", "iPad Pro")]:
            result = output / (family + ".xcresult")
            result.mkdir()
            receipt = output / (family + ".json")
            receipt.write_text(json.dumps({"app_source_sha256": context["app_source_sha256"], "result": str(result),
                                           "simulator_deleted": True}))
            review["ui_runs"].append({"family": family, "result": str(result),
                "capture_receipt": {"path": receipt.name, "sha256": release.digest(receipt)}})
            results[str(result)] = {"devices": [{"modelName": model}], "testNodes": [
                {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier": name + "()"} for name in (
                "MobileCardJourneyUITests/testCreateBrowseAndStudyBasicCardJourney",
                "MobileRedesignParityUITests/testAllFieldAuthoringMediaRemovalAndPickerCancellation")]}
        products = output / "derived-data/Build/Products"
        executable = products / "Release-iphonesimulator/NeoAnki2.app/NeoAnki2"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"optimized ordinary application")
        xctestrun = products / "production.xctestrun"
        xctestrun.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
            "BlueprintName": "NeoAnki2MobileUITests", "CommandLineArguments": [], "EnvironmentVariables": {},
            "UITargetAppPath": "__TESTROOT__/Release-iphonesimulator/NeoAnki2.app"}]}]}))
        proof = {"app_source_sha256": context["app_source_sha256"], "configuration": "Release", "optimization": "-O",
                 "launch_arguments": [], "launch_environment": {}, "test_fixture_seeded": False, "fresh_install": True,
                 "test": "NeoAnki2MobileUITests/" + release.PRODUCTION_REVIEW_TEST, "devices": [],
                 "simulator_executable_sha256": release.digest(executable), "xctestrun_sha256": release.digest(xctestrun)}
        proof_path = output / "production-proof.json"
        for family, model in [("iphone", "iPhone 17"), ("ipad", "iPad Pro")]:
            result = output / (family + "-production.xcresult")
            result.mkdir()
            proof["devices"].append({"result_bundle": str(result), "cleaned_up": True, "simulator_id": family + "-id"})
            results[str(result)] = {"devices": [{"modelName": model, "deviceId": family + "-id"}],
                "testNodes": [{"nodeType": "Test Case", "result": "Passed", "nodeIdentifier": release.PRODUCTION_REVIEW_TEST + "()"}]}
        proof_path.write_text(json.dumps(proof))
        for family in ("iphone", "ipad"):
            review["ui_runs"].append({"family": family, "production": True, "result": str(output / (family + "-production.xcresult")),
                "capture_receipt": {"path": proof_path.name, "sha256": release.digest(proof_path)}})
        def xcrun(argv):
            self.assertEqual(argv[:6], ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path"])
            return json.dumps(results[argv[6]]).encode()
        return output, context, review, results, xcrun

    def test_internal_review_accepts_independent_reviews_and_real_test_results(self):
        with tempfile.TemporaryDirectory() as folder:
            output, context, review, _, xcrun = self.review_fixture(folder)
            with patch.object(release, "run", side_effect=xcrun):
                accepted = release.validate_internal_review(review, context, output)
            self.assertEqual(accepted["reviewers"], ["product-agent", "compliance-agent"])
            self.assertEqual(set(accepted["passed_ui_tests"]), {"iphone", "ipad"})

    def test_internal_review_rejects_stale_source_build_listing_and_pixels(self):
        with tempfile.TemporaryDirectory() as folder:
            output, context, review, _, _ = self.review_fixture(folder)
            for field in ("source_sha256", "build_id", "localizations", "screenshots"):
                with self.subTest(field=field), self.assertRaisesRegex(release.ReleaseError, "stale"):
                    release.validate_internal_review(review, context | {field: "changed"}, output)
            (output / "capture.png").write_bytes(b"edited after review")
            with self.assertRaisesRegex(release.ReleaseError, "missing or changed"):
                release.validate_internal_review(review, context, output)

    def test_internal_review_rejects_self_review_superficial_flags_and_blockers(self):
        with tempfile.TemporaryDirectory() as folder:
            output, context, review, _, _ = self.review_fixture(folder)
            with self.assertRaises(release.ReleaseError):
                release.validate_internal_review({"passed": True}, context, output)
            review["reviewers"][1]["reviewer"] = review["reviewers"][0]["reviewer"]
            with self.assertRaisesRegex(release.ReleaseError, "distinct"):
                release.validate_internal_review(review, context, output)
            review["reviewers"][1]["reviewer"] = "compliance-agent"
            report = output / "product.json"
            data = json.loads(report.read_text())
            data["blocking_findings"] = [{"issue": "Clean library cannot create a card"}]
            report.write_text(json.dumps(data))
            review["reviewers"][0]["report"]["sha256"] = release.digest(report)
            with self.assertRaisesRegex(release.ReleaseError, "without blockers"):
                release.validate_internal_review(review, context, output)

    def test_internal_review_rejects_missing_scope_or_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            output, context, review, _, _ = self.review_fixture(folder)
            report = output / "product.json"
            data = json.loads(report.read_text())
            data["observations"].pop()
            report.write_text(json.dumps(data))
            review["reviewers"][0]["report"]["sha256"] = release.digest(report)
            with self.assertRaisesRegex(release.ReleaseError, "omitted"):
                release.validate_internal_review(review, context, output)

    def test_internal_review_rejects_skips_failures_old_inputs_and_wrong_device(self):
        for kind in ("Skipped", "Failed", "old-inputs", "wrong-device"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as folder:
                output, context, review, results, xcrun = self.review_fixture(folder)
                if kind in ("Skipped", "Failed"):
                    results[review["ui_runs"][0]["result"]]["testNodes"][0]["result"] = kind
                elif kind == "wrong-device":
                    results[review["ui_runs"][0]["result"]]["devices"][0]["modelName"] = "iPad Pro"
                else:
                    receipt = output / "iphone.json"
                    data = json.loads(receipt.read_text())
                    data["app_source_sha256"] = "previous-candidate"
                    receipt.write_text(json.dumps(data))
                    review["ui_runs"][0]["capture_receipt"]["sha256"] = release.digest(receipt)
                with patch.object(release, "run", side_effect=xcrun), self.assertRaises(release.ReleaseError):
                    release.validate_internal_review(review, context, output)

    def test_internal_review_rejects_missing_apple_issue_and_regression(self):
        with tempfile.TemporaryDirectory() as folder:
            output, context, review, _, xcrun = self.review_fixture(folder)
            context["rejection"] = {"issues": [{"id": "apple-2.1", "required_tests": ["CleanLibrary/testFirstCard"]}]}
            review["context_sha256"] = release.json_digest(context)
            for reviewer in review["reviewers"]:
                report = output / reviewer["report"]["path"]
                data = json.loads(report.read_text()) | {"context_sha256": review["context_sha256"]}
                report.write_text(json.dumps(data))
                reviewer["report"]["sha256"] = release.digest(report)
            with patch.object(release, "run", side_effect=xcrun):
                with self.assertRaisesRegex(release.ReleaseError, "every recorded"):
                    release.validate_internal_review(review, context, output)
                review["remediation"] = [{"issue_id": "apple-2.1", "detail": "Reproduced and fixed the rejection with a fresh-install first-card test on both devices.",
                                           "evidence_ids": ["actual-pixels"]}]
                with self.assertRaisesRegex(release.ReleaseError, "both iPhone and iPad"):
                    release.validate_internal_review(review, context, output)

    def test_production_review_rejects_debug_seeds_launch_flags_and_missing_artifacts(self):
        for mutation in ("configuration", "test_fixture_seeded", "launch_arguments", "fresh_install", "executable", "xctestrun"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as folder:
                output, context, review, _, xcrun = self.review_fixture(folder)
                proof_path = output / "production-proof.json"
                proof = json.loads(proof_path.read_text())
                if mutation == "executable":
                    (output / "derived-data/Build/Products/Release-iphonesimulator/NeoAnki2.app/NeoAnki2").write_bytes(b"changed")
                elif mutation == "xctestrun":
                    path = output / "derived-data/Build/Products/production.xctestrun"
                    data = plistlib.loads(path.read_bytes())
                    data["TestConfigurations"][0]["TestTargets"][0]["CommandLineArguments"] = ["-NeoAnkiUITestingSeed"]
                    path.write_bytes(plistlib.dumps(data))
                    proof["xctestrun_sha256"] = release.digest(path)
                else:
                    proof[mutation] = {"configuration": "Debug", "test_fixture_seeded": True,
                        "launch_arguments": ["-NeoAnkiUITesting"], "fresh_install": False}[mutation]
                proof_path.write_text(json.dumps(proof))
                for entry in review["ui_runs"]:
                    if entry.get("production"):
                        entry["capture_receipt"]["sha256"] = release.digest(proof_path)
                with patch.object(release, "run", side_effect=xcrun), self.assertRaises(release.ReleaseError):
                    release.validate_internal_review(review, context, output)

    def test_internal_review_rejects_old_uploaded_images_even_with_new_capture_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            output, context, review, _, xcrun = self.review_fixture(folder)
            context["screenshots"][0]["source_checksum"] = "0" * 32
            review["context_sha256"] = release.json_digest(context)
            for reviewer in review["reviewers"]:
                path = output / reviewer["report"]["path"]
                data = json.loads(path.read_text()) | {"context_sha256": review["context_sha256"]}
                path.write_text(json.dumps(data))
                reviewer["report"]["sha256"] = release.digest(path)
            with patch.object(release, "run", side_effect=xcrun), self.assertRaisesRegex(release.ReleaseError, "uploaded images"):
                release.validate_internal_review(review, context, output)

    def test_production_review_rejects_flags_and_fixtures_in_target_app_fields(self):
        for field, value in (("UITargetAppCommandLineArguments", ["-NeoAnkiUITestingReset"]),
                             ("UITargetAppEnvironmentVariables", {"NEOANKI_TEST_SCENARIO": "seeded-library"})):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as folder:
                output, context, review, _, xcrun = self.review_fixture(folder)
                path = output / "derived-data/Build/Products/production.xctestrun"
                configuration = plistlib.loads(path.read_bytes())
                configuration["TestConfigurations"][0]["TestTargets"][0][field] = value
                path.write_bytes(plistlib.dumps(configuration))
                proof_path = output / "production-proof.json"
                proof = json.loads(proof_path.read_text())
                proof["xctestrun_sha256"] = release.digest(path)
                proof_path.write_text(json.dumps(proof))
                for entry in review["ui_runs"]:
                    if entry.get("production"):
                        entry["capture_receipt"]["sha256"] = release.digest(proof_path)
                with patch.object(release, "run", side_effect=xcrun), self.assertRaisesRegex(release.ReleaseError, "injects"):
                    release.validate_internal_review(review, context, output)

    def test_removed_or_accepted_target_cannot_count_as_resubmission(self):
        submission = {"id": "original", "attributes": {"state": "UNRESOLVED_ISSUES"}}
        target = {"attributes": {"state": "REMOVED"},
                  "relationships": {"appStoreVersion": {"data": {"id": "version"}}}}
        sibling = {"attributes": {"state": "REJECTED", "resolved": True}}
        for state in ("REMOVED", "ACCEPTED"):
            target["attributes"]["state"] = state
            with self.subTest(state=state), self.assertRaisesRegex(release.ReleaseError, "cannot be resubmitted"):
                release.select_review_submission([submission], {"original": [target, sibling]}, "version")
        target["attributes"]["state"] = "REJECTED"
        target["attributes"]["resolved"] = True
        sibling["attributes"]["state"] = "REMOVED"
        self.assertEqual(release.select_review_submission([submission], {"original": [target, sibling]}, "version"),
                         (submission, True))

    def test_malformed_internal_review_receipts_raise_release_errors(self):
        for field in ("root", "evidence", "reviewers", "ui_runs", "screenshots", "remediation",
                      "report-root", "observations", "detail", "capture-root"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as folder:
                output, context, review, _, xcrun = self.review_fixture(folder)
                if field == "root":
                    review = []
                elif field in ("report-root", "observations", "detail"):
                    report = output / "product.json"
                    data = json.loads(report.read_text())
                    if field == "report-root":
                        data = []
                    elif field == "observations":
                        data["observations"] = None
                    else:
                        data["observations"][0]["detail"] = None
                    report.write_text(json.dumps(data))
                    review["reviewers"][0]["report"]["sha256"] = release.digest(report)
                elif field == "capture-root":
                    receipt = output / "iphone.json"
                    receipt.write_text("[]")
                    review["ui_runs"][0]["capture_receipt"]["sha256"] = release.digest(receipt)
                else:
                    review[field] = None
                with patch.object(release, "run", side_effect=xcrun), self.assertRaises(release.ReleaseError):
                    release.validate_internal_review(review, context, output)

    def test_rejected_submission_must_be_resolved_then_reused(self):
        submission = {"id": "original", "attributes": {"state": "UNRESOLVED_ISSUES"}}
        item = {"attributes": {"state": "REJECTED"}, "relationships": {"appStoreVersion": {"data": {"id": "version"}}}}
        with self.assertRaisesRegex(release.ReleaseError, "rejected review item"):
            release.select_review_submission([submission], {"original": [item]}, "version")
        submission["attributes"]["state"] = "READY_FOR_REVIEW"
        # Changing the submission state alone cannot conceal a rejected item.
        with self.assertRaises(release.ReleaseError):
            release.select_review_submission([submission], {"original": [item]}, "version")
        item["attributes"]["state"] = "READY_FOR_REVIEW"
        self.assertEqual(release.select_review_submission([submission], {"original": [item]}, "version"), (submission, True))

    def test_unresolved_submission_parent_can_resubmit_only_when_every_rejected_item_resolved(self):
        submission = {"id": "original", "attributes": {"state": "UNRESOLVED_ISSUES"}}
        target = {"attributes": {"state": "REJECTED", "resolved": True},
                  "relationships": {"appStoreVersion": {"data": {"id": "version"}}}}
        sibling = {"attributes": {"state": "REJECTED", "resolved": False}}
        with self.assertRaises(release.ReleaseError):
            release.select_review_submission([submission], {"original": [target, sibling]}, "version")
        sibling["attributes"]["resolved"] = True
        self.assertEqual(release.select_review_submission([submission], {"original": [target, sibling]}, "version"), (submission, True))

    def test_rejection_evidence_remains_mandatory_after_ready_state_and_resolved_item(self):
        with tempfile.TemporaryDirectory() as folder:
            state = {}
            version = {"id": "version", "attributes": {"appStoreState": "READY_FOR_REVIEW"}}
            submission = {"id": "original", "attributes": {"state": "UNRESOLVED_ISSUES"}}
            item = {"attributes": {"state": "REJECTED", "resolved": True},
                    "relationships": {"appStoreVersion": {"data": {"id": "version"}}}}
            release.record_rejections(state, [version], [submission], {"original": [item]})
            with self.assertRaisesRegex(release.ReleaseError, "even after"):
                release.require_rejection_record(state, "version", Path(folder) / "missing.json")
            # The sticky local receipt survives Apple's later parent/item transitions.
            submission["attributes"]["state"] = "READY_FOR_REVIEW"
            item["attributes"]["state"] = "READY_FOR_REVIEW"
            release.record_rejections(state, [version], [submission], {"original": [item]})
            self.assertEqual(state["rejected_version_ids"], ["version"])
            with self.assertRaises(release.ReleaseError):
                release.require_rejection_record(state, "version", Path(folder) / "missing.json")

    def test_submission_reconcile_blocks_duplicate_active_and_unresolved_other_versions(self):
        submissions = [{"id": name, "attributes": {"state": "READY_FOR_REVIEW"}} for name in ("one", "two")]
        item = {"attributes": {"state": "READY_FOR_REVIEW"}, "relationships": {"appStoreVersion": {"data": {"id": "version"}}}}
        with self.assertRaisesRegex(release.ReleaseError, "Multiple active"):
            release.select_review_submission(submissions, {s["id"]: [item] for s in submissions}, "version")
        submissions[0]["attributes"]["state"] = "UNRESOLVED_ISSUES"
        with self.assertRaisesRegex(release.ReleaseError, "Another iOS"):
            release.select_review_submission(submissions[:1], {"one": [item]}, "unrelated-version")

    def test_submission_reconcile_resumes_empty_owned_draft_and_ignores_completed_history(self):
        draft = {"id": "draft", "attributes": {"state": "READY_FOR_REVIEW"}}
        completed = {"id": "old", "attributes": {"state": "COMPLETE"}}
        items = {"draft": [], "old": [{"relationships": {"appStoreVersion": {"data": {"id": "version"}}}}]}
        self.assertEqual(release.select_review_submission([completed, draft], items, "version", "draft"), (draft, False))
        self.assertEqual(release.select_review_submission([completed], {"old": items["old"]}, "version"), (None, False))

    def test_metadata_only_binary_reuse_rejects_changed_production_inputs_or_missing_artifacts(self):
        with tempfile.TemporaryDirectory() as folder:
            candidate = Path(folder)
            archive = candidate / "NeoAnki2.xcarchive/Products/Applications/NeoAnki2.app/NeoAnki2"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"verified executable")
            ipa = candidate / "export/NeoAnki2.ipa"
            ipa.parent.mkdir()
            ipa.write_bytes(b"verified ipa")
            files = [{"path": "Sources/App.swift", "kind": "file", "sha256": "original"},
                     {"path": "Platforms/iOSUITests/Journey.swift", "kind": "file", "sha256": "old-test"}]
            state = {"source_sha256": release.json_digest(files), "version": "1.0.0", "build": "1", "build_id": "apple-build",
                "phases": {"archive": {"executable_sha256": release.digest(archive)}, "export": {"ipa_sha256": release.digest(ipa)},
                           "upload": {"status": "delivered", "ipa_sha256": release.digest(ipa)}}}
            (candidate / "source.json").write_text(json.dumps(files))
            (candidate / "release.json").write_text(json.dumps(state))
            test_changes = [files[0], files[1] | {"sha256": "new-test"}]
            self.assertEqual(release.reuse_binary_candidate(candidate, test_changes, "1.0.0", "1"), state)
            with self.assertRaisesRegex(release.ReleaseError, "production inputs changed"):
                release.reuse_binary_candidate(candidate, [files[0] | {"sha256": "new-code"}, files[1]], "1.0.0", "1")
            with self.assertRaisesRegex(release.ReleaseError, "version/build"):
                release.reuse_binary_candidate(candidate, files, "1.0.0", "2")
            ipa.write_bytes(b"tampered export")
            with self.assertRaisesRegex(release.ReleaseError, "verified archive"):
                release.reuse_binary_candidate(candidate, files, "1.0.0", "1")

    def test_real_manifest_only_edit_invalidates_binary_reuse_and_ui_receipts(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as artifact_folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            manifest = root / "Package.swift"
            manifest.write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "App")\n')
            subprocess.run(["git", "-C", str(root), "add", "Package.swift"], check=True)
            original_source, files = release.source_snapshot(root)
            candidate = Path(artifact_folder) / "candidate"
            archive = candidate / "NeoAnki2.xcarchive/Products/Applications/NeoAnki2.app/NeoAnki2"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"binary built from original package manifest")
            ipa = candidate / "export/NeoAnki2.ipa"
            ipa.parent.mkdir()
            ipa.write_bytes(b"signed original package build")
            state = {"source_sha256": original_source, "version": "1.0.0", "build": "1", "build_id": "apple-build",
                "phases": {"archive": {"executable_sha256": release.digest(archive)}, "export": {"ipa_sha256": release.digest(ipa)},
                           "upload": {"status": "delivered", "ipa_sha256": release.digest(ipa)}}}
            (candidate / "source.json").write_text(json.dumps(files))
            (candidate / "release.json").write_text(json.dumps(state))
            release.reuse_binary_candidate(candidate, files, "1.0.0", "1")
            previous_ui_hash = release.application_source(files)
            manifest.write_text(manifest.read_text().replace('Package(name: "App")',
                'Package(name: "App", dependencies: [.package(url: "https://example.org/library", from: "2.0.0")])'))
            _, current = release.source_snapshot(root)
            self.assertNotEqual(release.binary_source(files), release.binary_source(current))
            self.assertNotEqual(previous_ui_hash, release.application_source(current))
            with self.assertRaisesRegex(release.ReleaseError, "production inputs changed"):
                release.reuse_binary_candidate(candidate, current, "1.0.0", "1")
            output, context, review, _, xcrun = self.review_fixture(Path(artifact_folder) / "review")
            # Current independent reports cannot bless UI runs captured against
            # the old production manifest, even when their test names passed.
            context["app_source_sha256"] = release.application_source(current)
            review["context_sha256"] = release.json_digest(context)
            for entry in review["ui_runs"]:
                path = output / entry["capture_receipt"]["path"]
                data = json.loads(path.read_text()) | {"app_source_sha256": previous_ui_hash}
                path.write_text(json.dumps(data))
            for entry in review["ui_runs"]:
                entry["capture_receipt"]["sha256"] = release.digest(output / entry["capture_receipt"]["path"])
            for reviewer in review["reviewers"]:
                path = output / reviewer["report"]["path"]
                data = json.loads(path.read_text()) | {"context_sha256": review["context_sha256"]}
                path.write_text(json.dumps(data))
                reviewer["report"]["sha256"] = release.digest(path)
            with patch.object(release, "run", side_effect=xcrun), self.assertRaisesRegex(release.ReleaseError, "does not describe this candidate"):
                release.validate_internal_review(review, context, output)

    def test_ignored_swiftpm_resolution_and_configuration_are_production_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_text(".swiftpm/\n*.xcworkspace/\n")
            resolution = root / ".swiftpm/Package.resolved"
            resolution.parent.mkdir()
            resolution.write_text('{"pins": [{"identity": "library", "state": {"revision": "old"}}]}')
            configuration = root / ".swiftpm/configuration/mirrors.json"
            configuration.parent.mkdir()
            configuration.write_text('{"mirror": "https://example.org/old"}')
            _, previous = release.source_snapshot(root)
            self.assertIn(".swiftpm/Package.resolved", {f["path"] for f in previous})
            self.assertIn(".swiftpm/configuration/mirrors.json", {f["path"] for f in previous})
            for file in (resolution, configuration):
                file.write_text(file.read_text().replace("old", "new"))
                _, current = release.source_snapshot(root)
                self.assertNotEqual(release.binary_source(previous), release.binary_source(current))
                self.assertNotEqual(release.application_source(previous), release.application_source(current))
                previous = current
            resolution.unlink()
            _, current = release.source_snapshot(root)
            self.assertNotEqual(release.binary_source(previous), release.binary_source(current))

    def test_runner_delegates_to_same_manifest_sensitive_application_fingerprint(self):
        spec = importlib.util.spec_from_file_location("production_review_hash_test", Path(__file__).with_name("review-ios-app.py"))
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        files = [{"path": "Package.swift", "kind": "file", "sha256": "production-manifest"},
                 {"path": "Platforms/iOSUITests/Journey.swift", "kind": "file", "sha256": "test"}]
        with patch.object(runner.release, "source_snapshot", return_value=("source", files)):
            self.assertEqual(runner.application_source(), release.application_source(files))

    def profile(self, bundle=release.APP_ID):
        return {"ExpirationDate": dt.datetime(2030, 1, 1), "TeamIdentifier": [release.TEAM],
                "DeveloperCertificates": [b"certificate"], "Entitlements": {
                    "application-identifier": release.TEAM + "." + bundle,
                    "com.apple.developer.team-identifier": release.TEAM,
                    "get-task-allow": False, "aps-environment": "production",
                    "com.apple.developer.icloud-container-environment": ["Production"],
                    "com.apple.developer.icloud-services": ["CloudKit"],
                    "com.apple.developer.icloud-container-identifiers": ["iCloud.com.neoanki2.app"],
                    "com.apple.security.application-groups": ["group.com.neoanki2.shared"]}}

    def test_accepts_store_profile_and_production_entitlements(self):
        ent = release.validate_store_profile(self.profile(), release.APP_ID, b"certificate")
        self.assertEqual(ent["com.apple.developer.icloud-container-environment"], "Production")
        self.assertEqual(ent["aps-environment"], "production")

    def test_rejects_adhoc_and_enterprise_profiles(self):
        for extra in [{"ProvisionedDevices": ["phone"]}, {"ProvisionedDevices": []}, {"ProvisionsAllDevices": True}]:
            profile = self.profile() | extra
            with self.assertRaises(release.ReleaseError):
                release.validate_store_profile(profile, release.APP_ID, b"certificate")

    def test_rejects_identity_expiry_and_capability_mismatches(self):
        for change in ["team", "bundle", "expiry", "certificate", "debug", "cloudkit", "group", "push"]:
            profile = self.profile()
            ent = profile["Entitlements"]
            if change == "team": profile["TeamIdentifier"] = ["OTHER"]
            if change == "bundle": ent["application-identifier"] = release.TEAM + ".other"
            if change == "expiry": profile["ExpirationDate"] = dt.datetime(2000, 1, 1)
            if change == "certificate": profile["DeveloperCertificates"] = [b"different"]
            if change == "debug": ent["get-task-allow"] = True
            if change == "cloudkit": ent["com.apple.developer.icloud-container-environment"] = ["Development"]
            if change == "group": ent["com.apple.security.application-groups"] = []
            if change == "push": ent["aps-environment"] = "development"
            with self.subTest(change=change), self.assertRaises(release.ReleaseError):
                release.validate_store_profile(profile, release.APP_ID, b"certificate")

    def test_jwt_signature_width_and_sign_padding(self):
        r, s = b"\0" + b"\x80" * 32, b"\x01"
        body = b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        signature = release.raw_es256(b"\x30" + bytes([len(body)]) + body)
        self.assertEqual(signature, b"\x80" * 32 + b"\0" * 31 + b"\x01")
        for invalid in [b"", b"\x30\x00", b"\x30\x06\x02\x01\x80\x02\x01\x01"]:
            with self.assertRaises(release.ReleaseError): release.raw_es256(invalid)

    def test_failed_signing_preserves_archive_and_cleans_scratch_copy(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            source = output / "original.xcarchive"
            source.mkdir()
            binary = source / "binary"
            binary.write_bytes(b"verified unsigned binary")
            with self.assertRaisesRegex(RuntimeError, "export failed"):
                with release.signing_archive(source, output) as archive:
                    (archive / "binary").write_bytes(b"signed binary")
                    raise RuntimeError("export failed")
            self.assertEqual(binary.read_bytes(), b"verified unsigned binary")
            self.assertEqual(list(output.iterdir()), [source])

    def test_export_restores_keychain_search_after_failure_and_preserves_new_entries(self):
        calls = []
        def security(argv, **_):
            calls.append(argv)
            if "-s" not in argv:
                return (b'"original"\n"temporary"\n' if len(calls) == 1
                        else b'"temporary"\n"concurrent"\n')
            return b""
        with patch.object(release, "run", side_effect=security):
            with self.assertRaises(RuntimeError):
                with release.export_keychain_search(Path("temporary")):
                    raise RuntimeError("export failed")
        self.assertEqual(calls[1][-2:], ["-s", "temporary"])
        self.assertEqual(calls[-1][-3:], ["-s", "original", "concurrent"])

    def test_physical_waivers_require_explicit_option_and_user_authorization(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            proof = output / "proof.json"
            proof.write_text("verified candidate evidence")
            entry = {"passed": True, "evidence_file": proof.name, "sha256": release.digest(proof)}
            evidence = {"source_sha256": "source", "build_id": "build",
                        **{k: dict(entry) for k in ("production_cloudkit", *release.PHYSICAL_ACCEPTANCE, "ios_ui")}}
            evidence["two_device_sync"].update(passed=False, waived=True, reason="Second device unavailable")
            with self.assertRaises(release.ReleaseError):
                release.validate_acceptance(evidence, output, "source", "build", True)
            evidence["waiver_authorization"] = {"user_message": "Proceed with the reported gap",
                                                "known_incomplete_checks": ["two_device_sync"]}
            with self.assertRaises(release.ReleaseError):
                release.validate_acceptance(evidence, output, "source", "build")
            accepted = release.validate_acceptance(evidence, output, "source", "build", True)
            self.assertEqual(accepted["waived_checks"], ["two_device_sync"])
            self.assertNotIn("two_device_sync", accepted["passed_checks"])
            evidence["ios_ui"].update(passed=False, waived=True, reason="Must not bypass UI")
            evidence["waiver_authorization"]["known_incomplete_checks"].append("ios_ui")
            with self.assertRaises(release.ReleaseError):
                release.validate_acceptance(evidence, output, "source", "build", True)

    def test_api_refuses_to_forward_authentication_to_other_hosts(self):
        with tempfile.TemporaryDirectory() as folder:
            key = Path(folder) / "key.p8"
            key.write_text("test-only")
            api = release.AppleAPI({"key_id": "TEST", "issuer_id": "TEST", "private_key_path": str(key)})
            with patch.object(api, "token", side_effect=AssertionError("must not sign")):
                for path in ["https://evil.example/v1/apps", "http://api.appstoreconnect.apple.com/v1/apps"]:
                    with self.assertRaises(release.ReleaseError): api.request(path)

    def test_bundle_lookup_selects_exact_app_from_prefix_matches(self):
        api = object.__new__(release.AppleAPI)
        app = {"id": "app", "attributes": {"identifier": release.APP_ID}}
        widget = {"id": "widget", "attributes": {"identifier": release.WIDGET_ID}}
        with patch.object(api, "list", return_value=[widget, app]):
            self.assertEqual(api.bundle_identifier(release.APP_ID), app)
        with patch.object(api, "list", return_value=[widget]):
            with self.assertRaises(release.ReleaseError): api.bundle_identifier(release.APP_ID)

    def test_snapshot_detects_dirty_untracked_deleted_and_mode_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            file = root / "source.swift"
            file.write_text("original")
            subprocess.run(["git", "-C", str(root), "add", "source.swift"], check=True)
            previous = release.source_snapshot(root)[0]
            for action in [lambda: file.write_text("changed"), lambda: file.chmod(0o755),
                           lambda: (root / "untracked.swift").write_text("new"), lambda: file.unlink()]:
                action()
                current = release.source_snapshot(root)[0]
                self.assertNotEqual(current, previous)
                previous = current

    def test_existing_build_without_upload_receipt_is_not_claimed(self):
        flow = object.__new__(release.Workflow)
        flow.state = {"build": "1", "phases": {}}
        with patch.object(flow, "require_api"), patch.object(flow, "mark"), \
             patch.object(flow, "exact_build", return_value={"id": "other-build"}), \
             patch.object(flow, "export", side_effect=AssertionError("must not export")):
            with self.assertRaises(release.ReleaseError): flow.upload()

    def test_uncertain_upload_is_not_retried(self):
        flow = object.__new__(release.Workflow)
        flow.state = {"build": "1", "phases": {"upload": {"status": "attempting"}}}
        with patch.object(flow, "require_api"), patch.object(flow, "mark"), \
             patch.object(flow, "exact_build", return_value=None), \
             patch.object(flow, "export", side_effect=AssertionError("must not export")):
            with self.assertRaises(release.ReleaseError): flow.upload()

    def test_submission_requires_exact_build_and_auto_release(self):
        class API:
            def request(self, *_): return {"data": {"id": "wrong-build"}}
        flow = object.__new__(release.Workflow)
        flow.api = API()
        flow.state = {"phases": {"upload": {"status": "delivered"}}}
        build = {"id": "release-build", "attributes": {"processingState": "VALID"}}
        versions = [{"id": "version", "attributes": {"releaseType": "AFTER_APPROVAL", "appStoreState": "PREPARE_FOR_SUBMISSION"}}]
        with patch.object(flow, "verify_source"), patch.object(flow, "mark"), \
             patch.object(flow, "status", return_value=(build, versions)):
            with self.assertRaisesRegex(release.ReleaseError, "exact release build"): flow.submit()


if __name__ == "__main__":
    unittest.main()
