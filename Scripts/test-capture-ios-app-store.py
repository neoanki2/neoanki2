#!/usr/bin/env python3
"""Verify screenshot cache reuse cannot capture a stale application/test build."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("ios_capture_tests", Path(__file__).with_name("capture-ios-app-store.py"))
capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(capture)


class ScreenshotBuildSafetyTests(unittest.TestCase):
    def products(self, derived):
        products = derived / "Build/Products"
        app = products / "Debug-iphonesimulator/NeoAnki2.app/NeoAnki2"
        tests = products / "Debug-iphonesimulator/NeoAnki2MobileUITests-Runner.app/PlugIns/NeoAnki2MobileUITests.xctest/NeoAnki2MobileUITests"
        app.parent.mkdir(parents=True)
        tests.parent.mkdir(parents=True)
        app.write_bytes(b"candidate application executable")
        tests.write_bytes(b"candidate screenshot tests")
        run = products / "capture.xctestrun"
        run.write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{
            "BlueprintName": "NeoAnki2MobileUITests", "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/NeoAnki2.app"}]}]}))
        return {"executable": app, "test_binary": tests, "xctestrun": run}

    def record(self, derived, source="candidate-source"):
        with patch.object(capture, "app_source", return_value=source):
            return capture.record_capture_build(derived, source)

    def test_valid_cache_binds_app_test_executable_and_xctestrun(self):
        with tempfile.TemporaryDirectory() as folder:
            derived = Path(folder)
            products = self.products(derived)
            receipt = self.record(derived)
            self.assertEqual(capture.validate_capture_build(derived, "candidate-source"), receipt)
            self.assertEqual(set(receipt["products"]), set(products))

    def test_skip_build_requires_receipt_and_exact_candidate_source(self):
        with tempfile.TemporaryDirectory() as folder:
            derived = Path(folder)
            self.products(derived)
            with self.assertRaisesRegex(capture.release.ReleaseError, "requires a verified"):
                capture.validate_capture_build(derived, "candidate-source")
            self.record(derived)
            with self.assertRaisesRegex(capture.release.ReleaseError, "different application"):
                capture.validate_capture_build(derived, "changed-source")

    def test_changed_cached_app_tests_or_xctestrun_cannot_reuse_receipt(self):
        for name in ("executable", "test_binary", "xctestrun"):
            with self.subTest(product=name), tempfile.TemporaryDirectory() as folder:
                derived = Path(folder)
                products = self.products(derived)
                self.record(derived)
                if name == "xctestrun":
                    configuration = plistlib.loads(products[name].read_bytes())
                    configuration["StaleCache"] = True
                    products[name].write_bytes(plistlib.dumps(configuration))
                else:
                    products[name].write_bytes(b"different build contents")
                with self.assertRaisesRegex(capture.release.ReleaseError, "changed"):
                    capture.validate_capture_build(derived, "candidate-source")

    def test_wrong_app_path_and_ambiguous_test_products_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            derived = Path(folder)
            products = self.products(derived)
            configuration = plistlib.loads(products["xctestrun"].read_bytes())
            configuration["TestConfigurations"][0]["TestTargets"][0]["UITargetAppPath"] = "__TESTROOT__/Other.app"
            products["xctestrun"].write_bytes(plistlib.dumps(configuration))
            with self.assertRaisesRegex(capture.release.ReleaseError, "does not reference"):
                self.record(derived)
            (derived / "Build/Products/second.xctestrun").write_bytes(products["xctestrun"].read_bytes())
            with self.assertRaisesRegex(capture.release.ReleaseError, "one complete"):
                self.record(derived)

    def test_real_package_manifest_only_edit_invalidates_screenshot_cache(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as build_folder:
            root, derived = Path(folder), Path(build_folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            package = root / "Package.swift"
            package.write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "App")\n')
            subprocess.run(["git", "-C", str(root), "add", "Package.swift"], check=True)
            _, before = capture.release.source_snapshot(root)
            old_fingerprint = capture.release.application_source(before)
            self.products(derived)
            self.record(derived, old_fingerprint)
            package.write_text(package.read_text().replace('Package(name: "App")',
                'Package(name: "App", dependencies: [.package(url: "https://example.org/changed", from: "2.0.0")])'))
            _, after = capture.release.source_snapshot(root)
            current = capture.release.application_source(after)
            self.assertNotEqual(current, old_fingerprint)
            with patch.object(capture.release, "source_snapshot", return_value=("source", after)):
                self.assertEqual(capture.app_source(), current)
            with self.assertRaisesRegex(capture.release.ReleaseError, "different application"):
                capture.validate_capture_build(derived, current)

    def test_source_change_during_build_does_not_write_cache_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            derived = Path(folder)
            self.products(derived)
            with patch.object(capture, "app_source", return_value="edited-mid-build"):
                with self.assertRaisesRegex(capture.release.ReleaseError, "changed during"):
                    capture.record_capture_build(derived, "candidate-source")
            self.assertFalse((derived / "capture-build.json").exists())

    def test_failed_fresh_build_invalidates_cache_without_creating_simulator(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            derived = root / ".build/ios-store-ui"
            self.products(derived)
            self.record(derived)
            calls = []
            def build(argv, **_):
                calls.append(argv)
                raise capture.release.ReleaseError("Build failed")
            with patch.object(capture, "ROOT", root), patch.object(capture, "app_source", return_value="candidate-source"), \
                 patch.object(capture.release, "source_snapshot", return_value=("source", [])), \
                 patch.object(capture, "run", side_effect=build), \
                 patch.object(sys, "argv", ["capture-ios-app-store.py", "--output", str(root / "new-capture")]):
                with self.assertRaisesRegex(capture.release.ReleaseError, "Build failed"):
                    capture.main()
            self.assertEqual(len(calls), 1)
            self.assertIn("build-for-testing", calls[0])
            self.assertFalse((derived / "capture-build.json").exists())

    def test_existing_screenshot_evidence_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            receipt = output / "screenshots.json"
            receipt.write_text('{"original": true}')
            with patch.object(capture, "run", side_effect=AssertionError("must not build or boot")), \
                 patch.object(sys, "argv", ["capture-ios-app-store.py", "--output", str(output)]):
                with self.assertRaisesRegex(capture.release.ReleaseError, "preserve existing"):
                    capture.main()
            self.assertEqual(receipt.read_text(), '{"original": true}')

    def test_malformed_cache_receipts_fail_with_release_errors(self):
        for field in ("root", "products", "product"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as folder:
                derived = Path(folder)
                self.products(derived)
                receipt = self.record(derived)
                if field == "root":
                    receipt = []
                elif field == "products":
                    receipt["products"] = None
                else:
                    receipt["products"]["executable"] = None
                (derived / "capture-build.json").write_text(json.dumps(receipt))
                with self.assertRaises(capture.release.ReleaseError):
                    capture.validate_capture_build(derived, "candidate-source")


if __name__ == "__main__":
    unittest.main()
