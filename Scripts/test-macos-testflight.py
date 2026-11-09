#!/usr/bin/env python3
"""Integrity-boundary regression tests; no signing, launch, or Apple mutation."""
import copy
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("testflight", Path(__file__).with_name("validate-macos-testflight.py"))
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)


def thin(cpu=0x100000C, subtype=0, signature=b"signature", text=b"0123456789abcdef", identifier=b"0123456789abcdef"):
    vm = 0x100000000
    segment = struct.pack("<II16s4Q4I", 0x19, 152, b"__TEXT", vm, 4096, 0, 384, 7, 5, 1, 0)
    section = struct.pack("<16s16s2Q8I", b"__text", b"__TEXT", vm + 320, 16, 320, 4, 0, 0, 0x80000400, 0, 0, 0)
    linkedit = struct.pack("<II16s4Q4I", 0x19, 72, b"__LINKEDIT", vm + 4096,
                           (16 + len(signature) + 4095) // 4096 * 4096,
                           384, 16 + len(signature), 1, 1, 0, 0)
    commands = segment + section + linkedit + struct.pack("<II16s", 0x1B, 24, identifier) + struct.pack("<4I", 0x1D, 16, 400, len(signature))
    header = struct.pack("<8I", 0xFEEDFACF, cpu, subtype, 2, 4, len(commands), 0x200085, 0)
    content = header + commands
    return content.ljust(320, b"\0") + text + b"\0" * 48 + b"linkedit-content" + signature


def fat(slices):
    count = len(slices)
    data = bytearray(4096 * (count + 1))
    struct.pack_into(">II", data, 0, 0xCAFEBABE, count)
    for i, value in enumerate(slices):
        cpu, subtype = struct.unpack_from("<II", value, 4)
        offset = (i + 1) * 4096
        struct.pack_into(">5I", data, 8 + i * 20, cpu, subtype, offset, len(value), 12)
        data[offset:offset + len(value)] = value
    return bytes(data)


class MachOTests(unittest.TestCase):
    def test_signature_replacement_allowed_but_text_and_uuid_unchanged(self):
        self.assertEqual(tf.macho_fingerprint(thin()), tf.macho_fingerprint(thin(signature=b"s" * 5000)))
        self.assertNotEqual(tf.macho_fingerprint(thin()), tf.macho_fingerprint(thin(text=b"x" * 16)))
        self.assertNotEqual(tf.macho_fingerprint(thin()), tf.macho_fingerprint(thin(identifier=b"x" * 16)))

    def test_unsectioned_linkedit_change_is_detected(self):
        value = bytearray(thin())
        value[390] ^= 1
        self.assertNotEqual(tf.macho_fingerprint(thin()), tf.macho_fingerprint(bytes(value)))

    def test_architecture_thinning_preserves_per_arch_identity(self):
        arm, intel = thin(), thin(cpu=0x1000007, subtype=3)
        original = tf.macho_fingerprint(fat([intel, arm]))
        self.assertEqual(original["0100000c:00000000"], tf.macho_fingerprint(arm)["0100000c:00000000"])

    def test_truncation_signature_bounds_and_command_bounds_rejected(self):
        values = [b"", thin()[:20], thin()[:-1]]
        command = bytearray(thin()); struct.pack_into("<I", command, 36, 0xFFFFFFFF); values.append(command)
        for value in values:
            with self.subTest(size=len(value)), self.assertRaises(ValueError):
                tf.macho_fingerprint(value)

    def test_fat_overlap_and_mismatched_cpu_rejected(self):
        original = fat([thin(), thin(cpu=0x1000007, subtype=3)])
        overlap = bytearray(original); struct.pack_into(">I", overlap, 8 + 20 + 8, 4096)
        mismatch = bytearray(original); struct.pack_into(">I", mismatch, 8, 7)
        for value in (overlap, mismatch):
            with self.assertRaises(ValueError): tf.macho_fingerprint(value)


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="neoanki-testflight-test-")
        self.addCleanup(self.temp.cleanup)
        self.export = Path(self.temp.name) / "export/NeoAnki2.app"
        self.install = Path(self.temp.name) / "installed/NeoAnki2.app"
        self.expected = {"version": "1.0.1", "build": "2", "source_revision": "a" * 40,
                         "source_sha256": "b" * 64, "build_id": "12345678-1234-1234-1234-123456789abc"}
        info = {"CFBundleIdentifier": tf.APP_ID, "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "2",
                "CFBundleExecutable": "NeoAnki2", "NeoAnkiGitRevision": "a" * 40}
        for app, sig in ((self.export, b"export-signature"), (self.install, b"apple-signature" * 8)):
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            (app / "Contents/MacOS/NeoAnki2").write_bytes(thin(signature=sig))
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            (app / "Contents/Resources/PrivacyInfo.xcprivacy").write_bytes(b"privacy build2")
        (self.install / "Contents/_MASReceipt").mkdir()
        (self.install / "Contents/_MASReceipt/receipt").write_bytes(b"opaque signed receipt fixture")
        self.entitlements = {str(self.export.resolve()): copy.deepcopy(tf.REQUIRED_ENTITLEMENTS),
                             str(self.install.resolve()): {**copy.deepcopy(tf.REQUIRED_ENTITLEMENTS), "beta-reports-active": True}}
        self.commands = []
        def fake_run(argv):
            self.commands.append(argv)
            if "--entitlements" in argv:
                return plistlib.dumps(self.entitlements[argv[-1]])
            return b""
        self.mock = patch.object(tf, "run", side_effect=fake_run)
        self.mock.start(); self.addCleanup(self.mock.stop)

    def validate(self):
        return tf.validate_testflight_app(self.install, self.export, self.expected)

    def test_success_is_stable_and_uses_exclusive_testflight_requirement(self):
        proof = self.validate()
        self.assertEqual(proof, self.validate())
        self.assertNotEqual(proof["installed_executable_sha256"], proof["exported_executable_sha256"])
        self.assertEqual(proof["expected"], self.expected)
        checks = [x for x in self.commands if "-R" in x]
        self.assertEqual(checks[0][-2], "=" + tf.APPLE_REQUIREMENT)
        self.assertIn("1.2.840.113635.100.6.1.25.1", checks[0][-2])
        self.assertNotIn(" or ", checks[0][-2])
        self.assertFalse(proof["receipt"]["cryptographically_validated"])

    def test_signing_failure_is_not_ignored(self):
        with patch.object(tf, "run", side_effect=RuntimeError("invalid Apple signature")):
            with self.assertRaises(RuntimeError): self.validate()

    def test_stale_identity_rejected(self):
        for key, value in (("build", "1"), ("version", "1.0.0"), ("source_revision", "c" * 40)):
            with self.subTest(key=key):
                expected = {**self.expected, key: value}
                with self.assertRaises(ValueError): tf.validate_testflight_app(self.install, self.export, expected)

    def test_export_debug_install_debug_and_sandbox_reduction_rejected(self):
        for app, key, value in ((self.export, "get-task-allow", True),
                                (self.install, "com.apple.security.get-task-allow", True),
                                (self.install, "com.apple.security.app-sandbox", False),
                                (self.install, "com.apple.developer.icloud-container-environment", "Development")):
            original = copy.deepcopy(self.entitlements[str(app.resolve())])
            with self.subTest(app=app, key=key):
                self.entitlements[str(app.resolve())][key] = value
                with self.assertRaises(ValueError): self.validate()
                self.entitlements[str(app.resolve())] = original

    def test_beta_marker_and_receipt_required(self):
        self.entitlements[str(self.install.resolve())].pop("beta-reports-active")
        with self.assertRaises(ValueError): self.validate()
        self.entitlements[str(self.install.resolve())]["beta-reports-active"] = True
        (self.install / "Contents/_MASReceipt/receipt").unlink()
        with self.assertRaises(ValueError): self.validate()

    def test_changed_privacy_resource_and_added_file_rejected(self):
        resource = self.install / "Contents/Resources/PrivacyInfo.xcprivacy"
        resource.write_bytes(b"privacy build1")
        with self.assertRaises(ValueError): self.validate()
        resource.write_bytes(b"privacy build2")
        (self.install / "Contents/Resources/injected.dylib").write_bytes(b"extra")
        with self.assertRaises(ValueError): self.validate()

    def test_code_tamper_and_export_receipt_hash_rejected(self):
        binary = self.install / "Contents/MacOS/NeoAnki2"
        binary.write_bytes(thin(text=b"x" * 16))
        with self.assertRaises(ValueError): self.validate()
        binary.write_bytes(thin())
        self.expected["phases"] = {"export": {"executable_sha256": "0" * 64}}
        with self.assertRaises(ValueError): self.validate()

    def test_unexpected_info_and_entitlement_changes_rejected(self):
        path = self.install / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes()); info["NSMicrophoneUsageDescription"] = "changed"
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError): self.validate()
        del info["NSMicrophoneUsageDescription"]; path.write_bytes(plistlib.dumps(info))
        self.entitlements[str(self.install.resolve())]["com.apple.security.cs.disable-library-validation"] = True
        with self.assertRaises(ValueError): self.validate()

    def test_symlink_payload_and_same_export_path_rejected(self):
        with self.assertRaises(ValueError): tf.validate_testflight_app(self.export, self.export, self.expected)
        (self.install / "Contents/Resources/link").symlink_to("PrivacyInfo.xcprivacy")
        with self.assertRaises(ValueError): self.validate()


if __name__ == "__main__":
    unittest.main()
