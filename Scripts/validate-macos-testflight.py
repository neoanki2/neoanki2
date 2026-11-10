#!/usr/bin/env python3
"""Read-only, fail-closed comparison of an Apple beta install and its export.

Apple re-signs TestFlight apps (TN3161). Raw executable hashes therefore differ.
This deliberately accepts only signature replacement and architecture thinning;
any other processing needs investigation, not a weaker automatic fallback.
An opaque receipt does NOT expose the App Store Connect build UUID: the caller
must retain authenticated TestFlight acquisition/build context separately.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import uuid

APP_ID = "com.neoanki2.ios"
TEAM_ID = "637635WK8L"
# Apple WWDR CPS 4.11.15 identifies this TestFlight-specific leaf extension:
# https://images.apple.com/certificateauthority/pdf/Apple_WWDR_CPS_v1.32.pdf
# Independently checked against the real installed beta's leaf certificate.
# Requiring this leaf excludes raw Apple Distribution and public Store apps.
APPLE_REQUIREMENT = ('anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.25.1] '
                     'and certificate leaf[subject.CN] = "TestFlight Beta Distribution" '
                     'and identifier "' + APP_ID + '"')
REQUIRED_ENTITLEMENTS = {
    "com.apple.application-identifier": TEAM_ID + "." + APP_ID,
    "com.apple.developer.team-identifier": TEAM_ID,
    "com.apple.developer.aps-environment": "production",
    "com.apple.developer.icloud-container-environment": "Production",
    "com.apple.developer.icloud-container-identifiers": ["iCloud.com.neoanki2.app"],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.ubiquity-kvstore-identifier": TEAM_ID + "." + APP_ID,
    "com.apple.security.app-sandbox": True,
    "com.apple.security.files.user-selected.read-write": True,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.network.client": True,
    "com.apple.security.network.server": True,
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(argv):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode:
        raise RuntimeError("Command failed: " + repr(argv) + "\n" + result.stderr.decode(errors="replace"))
    return result.stdout


def _thin(data):
    """Canonicalize only signature fields, retaining all other pre-signature bytes."""
    if data[:4] == b"\xcf\xfa\xed\xfe":
        order = "<"
    elif data[:4] == b"\xfe\xed\xfa\xcf":
        order = ">"
    else:
        raise ValueError("Expected a 64-bit Mach-O")
    if len(data) < 32:
        raise ValueError("Truncated Mach-O header")
    _, cpu, subtype, _, count, size, _, _ = struct.unpack_from(order + "8I", data)
    if count > 4096 or size > len(data) - 32:
        raise ValueError("Invalid Mach-O load-command bounds")
    end, cursor, signature, identifier = 32 + size, 32, None, None
    mutable, sections = [], []
    linkedit = None
    for _ in range(count):
        if cursor + 8 > end:
            raise ValueError("Truncated load command")
        cmd, length = struct.unpack_from(order + "II", data, cursor)
        if length < 8 or length % 4 or cursor + length > end:
            raise ValueError("Invalid load-command length")
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            if length != 16 or signature is not None:
                raise ValueError("Invalid/duplicate code signature command")
            offset, amount = struct.unpack_from(order + "II", data, cursor + 8)
            if offset < end or amount == 0 or offset + amount != len(data):
                raise ValueError("Signature must terminate its Mach-O slice")
            signature = (offset, amount)
            mutable.append((cursor + 8, 8))
        elif cmd == 0x1B:  # LC_UUID
            if length != 24 or identifier is not None:
                raise ValueError("Invalid/duplicate Mach-O UUID")
            identifier = str(uuid.UUID(bytes=data[cursor + 8:cursor + 24]))
        elif cmd == 0x19:  # LC_SEGMENT_64
            if length < 72:
                raise ValueError("Truncated segment")
            segment = data[cursor + 8:cursor + 24].rstrip(b"\0").decode("ascii")
            vmaddr, vmsize, fileoff, filesize, _, _, nsections, _ = struct.unpack_from(order + "4Q4I", data, cursor + 24)
            if length != 72 + nsections * 80 or fileoff + filesize > len(data):
                raise ValueError("Invalid segment bounds")
            if segment == "__LINKEDIT":
                if linkedit is not None:
                    raise ValueError("Duplicate __LINKEDIT")
                linkedit = (fileoff, filesize)
                # Replacing the final signature can change the segment extent.
                mutable.extend([(cursor + 32, 8), (cursor + 48, 8)])
            for i in range(nsections):
                pos = cursor + 72 + i * 80
                name = data[pos:pos + 16].rstrip(b"\0").decode("ascii")
                segname = data[pos + 16:pos + 32].rstrip(b"\0").decode("ascii")
                addr, amount, offset, align, _, _, flags, _, _, _ = struct.unpack_from(order + "2Q8I", data, pos + 32)
                zero = flags & 0xFF in (1, 12, 18)
                if segname != segment or addr < vmaddr or addr + amount > vmaddr + vmsize:
                    raise ValueError("Section lies outside its segment")
                if not zero and (offset < fileoff or offset + amount > fileoff + filesize):
                    raise ValueError("Section file content lies outside its segment")
                sections.append({"segment": segment, "section": name, "address": addr,
                                 "size": amount, "alignment": align, "flags": flags,
                                 "sha256": None if zero else digest(data[offset:offset + amount])})
        cursor += length
    if cursor != end or signature is None or identifier is None or linkedit is None:
        raise ValueError("Missing UUID/signature/LINKEDIT or inconsistent load commands")
    if not any(s["segment"] == "__TEXT" and s["section"] == "__text" and s["size"] for s in sections):
        raise ValueError("No executable text section")
    if linkedit[0] + linkedit[1] != len(data) or linkedit[0] > signature[0]:
        raise ValueError("Invalid final LINKEDIT extent")
    # No section may hide in the ignored signature blob.
    canonical = bytearray(data[:signature[0]])
    for start, amount in mutable:
        canonical[start:start + amount] = b"\0" * amount
    return f"{cpu:08x}:{subtype:08x}", {
        "uuid": identifier, "unsigned_content_sha256": digest(canonical),
        "signature_offset": signature[0], "sections": sections,
    }


def macho_fingerprint(data):
    """Return per-CPU identities; support fat32/fat64 and a thinned install."""
    data = bytes(data)
    magic = data[:4]
    variants = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
                b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if magic not in variants:
        key, result = _thin(data)
        return {key: result}
    order, wide = variants[magic]
    if len(data) < 8:
        raise ValueError("Truncated fat header")
    count = struct.unpack_from(order + "I", data, 4)[0]
    stride = 32 if wide else 20
    table_end = 8 + count * stride
    if not 1 <= count <= 16 or table_end > len(data):
        raise ValueError("Invalid fat architecture table")
    result, ranges = {}, []
    for i in range(count):
        pos = 8 + i * stride
        cpu, subtype = struct.unpack_from(order + "II", data, pos)
        offset, amount = struct.unpack_from(order + ("QQ" if wide else "II"), data, pos + 8)
        if offset < table_end or amount == 0 or offset + amount > len(data):
            raise ValueError("Invalid fat slice bounds")
        if any(offset < old_end and offset + amount > old_start for old_start, old_end in ranges):
            raise ValueError("Overlapping fat slices")
        ranges.append((offset, offset + amount))
        key, proof = _thin(data[offset:offset + amount])
        if key != f"{cpu:08x}:{subtype:08x}" or key in result:
            raise ValueError("Mismatched/duplicate fat architecture")
        result[key] = proof
    return result


def _resources(app, executable):
    result = {}
    for path in sorted(app.rglob("*")):
        rel = path.relative_to(app).as_posix()
        # Signature, provisioning and receipt are necessarily replaced by Apple.
        if rel.startswith("Contents/_CodeSignature/") or rel in (
            "Contents/Info.plist", "Contents/embedded.provisionprofile",
            "Contents/_MASReceipt/receipt", "Contents/_MASReceipt/sandboxReceipt", executable):
            continue
        if path.is_symlink():
            raise ValueError("Symlinks require explicit review: " + rel)
        if path.is_file():
            result[rel] = digest(path.read_bytes())
        elif not path.is_dir():
            raise ValueError("Unsupported bundle entry: " + rel)
    return result


def _info(app, expected):
    result = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    identity = {"CFBundleIdentifier": APP_ID, "CFBundleShortVersionString": str(expected["version"]),
                "CFBundleVersion": str(expected["build"]), "NeoAnkiGitRevision": expected["source_revision"],
                "CFBundleExecutable": "NeoAnki2"}
    if any(result.get(k) != v for k, v in identity.items()):
        raise ValueError("App Info.plist does not match the expected candidate")
    return result


def _entitlements(app):
    return plistlib.loads(run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)]))


def validate_testflight_app(installed_app: Path, exported_app: Path, expected: dict):
    """Validate without launching, stripping, signing, or modifying either app.

    expected is the authenticated release context (five identity fields plus,
    optionally, phases.export.executable_sha256 for retained-export integrity).
    Result is deterministic so before/after review receipts can compare it.
    """
    for key in ("version", "build", "source_revision", "source_sha256", "build_id"):
        if not isinstance(expected.get(key), str) or not expected[key]:
            raise ValueError("Missing candidate field: " + key)
    if not re.fullmatch(r"[0-9a-f]{40}", expected["source_revision"]) or not re.fullmatch(r"[0-9a-f]{64}", expected["source_sha256"]):
        raise ValueError("Invalid candidate source identity")
    if str(uuid.UUID(expected["build_id"])) != expected["build_id"].lower():
        raise ValueError("Invalid Apple build UUID")
    if expected.get("bundle_id", APP_ID) != APP_ID or expected.get("team_id", TEAM_ID) != TEAM_ID:
        raise ValueError("Unexpected release bundle/team")
    installed_app, exported_app = Path(installed_app).resolve(), Path(exported_app).resolve()
    if installed_app == exported_app:
        raise ValueError("Review requires a separate Apple-installed app")
    # Reject symlink payloads before reading any executable or Info.plist.
    for app in (installed_app, exported_app):
        if not app.is_dir() or app.suffix != ".app" or any(p.is_symlink() for p in app.rglob("*")):
            raise ValueError("Expected a regular app bundle without symlinks")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app)])
    run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "-R", "=" + APPLE_REQUIREMENT, str(installed_app)])
    installed_info, exported_info = _info(installed_app, expected), _info(exported_app, expected)
    info_changes = {k: {"exported": exported_info.get(k), "installed": installed_info.get(k)}
                    for k in installed_info.keys() | exported_info.keys() if installed_info.get(k) != exported_info.get(k)}
    if set(info_changes) - {"DTAppStoreToolsBuild"}:
        raise ValueError("Unexpected Apple Info.plist transformation: " + repr(sorted(info_changes)))
    installed_ent, exported_ent = _entitlements(installed_app), _entitlements(exported_app)
    allowed_extra_keys = {"beta-reports-active", "get-task-allow", "com.apple.security.get-task-allow"}
    for ent in (installed_ent, exported_ent):
        if ent.keys() - REQUIRED_ENTITLEMENTS.keys() - allowed_extra_keys:
            raise ValueError("Unreviewed entitlement outside the Store sandbox configuration")
        if any(ent.get(k) != v or type(ent.get(k)) is not type(v) for k, v in REQUIRED_ENTITLEMENTS.items()):
            raise ValueError("Missing/changed Production sandbox entitlement")
        if ent.get("get-task-allow", False) is not False or ent.get("com.apple.security.get-task-allow", False) is not False:
            raise ValueError("Debug entitlement is prohibited")
        if "beta-reports-active" in ent and ent["beta-reports-active"] is not True:
            raise ValueError("Invalid beta entitlement")
    for key, value in exported_ent.items():
        if installed_ent.get(key) != value:
            raise ValueError("Apple install changed an exported entitlement: " + key)
    added_entitlements = {k: v for k, v in installed_ent.items() if k not in exported_ent}
    allowed_additions = {"beta-reports-active": True, "get-task-allow": False,
                         "com.apple.security.get-task-allow": False}
    if any(k not in allowed_additions or v is not allowed_additions[k] for k, v in added_entitlements.items()):
        raise ValueError("Unexpected Apple-added entitlement: " + repr(added_entitlements))
    if installed_ent.get("beta-reports-active") is not True:
        raise ValueError("No signed beta-reports-active marker; inspect actual Apple beta provenance")
    executable = "Contents/MacOS/NeoAnki2"
    installed_bytes = (installed_app / executable).read_bytes()
    exported_bytes = (exported_app / executable).read_bytes()
    retained_hash = expected.get("phases", {}).get("export", {}).get("executable_sha256")
    if retained_hash is not None and digest(exported_bytes) != retained_hash:
        raise ValueError("Retained export checksum changed")
    installed_arch, exported_arch = macho_fingerprint(installed_bytes), macho_fingerprint(exported_bytes)
    if not installed_arch.keys() <= exported_arch.keys() or any(v != exported_arch[k] for k, v in installed_arch.items()):
        raise ValueError("Apple-installed Mach-O differs beyond re-signing/thinning")
    installed_resources, exported_resources = _resources(installed_app, executable), _resources(exported_app, executable)
    if installed_resources != exported_resources:
        raise ValueError("Apple-installed resources differ from the exact export")
    receipts = [p for p in (installed_app / "Contents/_MASReceipt").glob("*") if p.name in ("receipt", "sandboxReceipt")]
    if len(receipts) != 1 or not receipts[0].is_file() or receipts[0].stat().st_size == 0:
        raise ValueError("Expected exactly one nonempty Apple app receipt")
    return {
        "schema_version": 1, "validation": "apple-beta-signature-and-export-equivalence",
        "expected": {k: expected[k] for k in ("version", "build", "source_revision", "source_sha256", "build_id")},
        "bundle_id": APP_ID, "team_id": TEAM_ID, "installed_app": str(installed_app), "exported_app": str(exported_app),
        "apple_signing_requirement": APPLE_REQUIREMENT, "beta_reports_active": True,
        "installed_executable_sha256": digest(installed_bytes), "exported_executable_sha256": digest(exported_bytes),
        "architectures": installed_arch, "omitted_export_architectures": sorted(exported_arch.keys() - installed_arch.keys()),
        "resources": installed_resources, "entitlements": installed_ent, "info_changes": info_changes,
        "receipt": {"path": str(receipts[0]), "sha256": digest(receipts[0].read_bytes()),
                    "bytes": receipts[0].stat().st_size, "cryptographically_validated": False},
        "limitations": ["Apple build UUID/source snapshot hash are bound from authenticated caller context, not decoded from the binary or receipt.",
                        "Receipt is retained as opaque evidence; TestFlight acquisition must also have independent authenticated evidence.",
                        "Unknown Apple processing fails closed; this proof is not an Apple approval or a product journey result."],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installed-app", required=True, type=Path)
    parser.add_argument("--exported-app", required=True, type=Path)
    parser.add_argument("--expected", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(validate_testflight_app(args.installed_app, args.exported_app,
                                            json.loads(args.expected.read_text())), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
