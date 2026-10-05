#!/usr/bin/env python3
"""Developer ID + production CloudKit signing; notarization for distribution.

Uses saved PEM material in a disposable Keychain; never unlocks the user's
signing Keychain or falls back to an ad-hoc signature.
"""
import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SIGNING = Path.home() / "Library/Application Support/NeoAnki2 Signing"
APP_ID = "com.neoanki2.app"
CONTAINER = "iCloud.com.neoanki2.app"


class SigningError(Exception):
    pass


def run(args, timeout=60):
    # Keychain commands contain generated passwords. Never print argv/output.
    try:
        result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise SigningError(f"{args[0]} timed out") from None
    if result.returncode:
        raise SigningError(f"{args[0]} failed (exit {result.returncode})")
    return result.stdout


def validate_profile(profile, certificate=None, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime) or expiry.replace(tzinfo=dt.timezone.utc) <= now:
        raise SigningError("Mac Developer ID provisioning profile is expired")
    teams = profile.get("TeamIdentifier", [])
    if len(teams) != 1 or not profile.get("ProvisionsAllDevices") or "OSX" not in profile.get("Platform", []):
        raise SigningError("Expected a Mac Developer ID provisioning profile")
    team = teams[0]
    allowed = profile.get("Entitlements", {})
    if allowed.get("com.apple.application-identifier") != team + "." + APP_ID:
        raise SigningError("Mac profile does not match NeoAnki2's bundle identifier")
    if allowed.get("com.apple.developer.team-identifier") != team:
        raise SigningError("Mac profile has an inconsistent team identifier")
    if certificate is not None and certificate not in profile.get("DeveloperCertificates", []):
        raise SigningError("Developer ID certificate is not included in the Mac profile")
    services = allowed.get("com.apple.developer.icloud-services", [])
    if (CONTAINER not in allowed.get("com.apple.developer.icloud-container-identifiers", [])
            or (services != "*" and "CloudKit" not in services)
            or allowed.get("com.apple.developer.icloud-container-environment") != "Production"
            or allowed.get("com.apple.developer.aps-environment") != "production"):
        raise SigningError("Mac profile must authorize production CloudKit and push notifications")
    if allowed.get("get-task-allow", False):
        raise SigningError("Mac distribution profile enables debugger access")
    kvstore = allowed.get("com.apple.developer.ubiquity-kvstore-identifier", "")
    if kvstore not in (team + ".*", team + "." + APP_ID):
        raise SigningError("Mac profile does not authorize NeoAnki2's iCloud key-value store")
    return team


def entitlements_for(team):
    entitlements = plistlib.loads((ROOT / "Packaging/NeoAnki2.entitlements").read_bytes())
    entitlements.update({
        "com.apple.application-identifier": team + "." + APP_ID,
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.icloud-container-environment": "Production",
        "com.apple.developer.ubiquity-kvstore-identifier": team + "." + APP_ID,
    })
    return entitlements


def validate_entitlements(entitlements, team):
    required = entitlements_for(team)
    for key, expected in required.items():
        if entitlements.get(key) != expected:
            raise SigningError(f"Signed app has an incorrect or missing entitlement: {key}")
    if entitlements.get("com.apple.security.get-task-allow", False):
        raise SigningError("Signed app enables debugger access")


class Material:
    def __init__(self, directory, require_notarization=True):
        self.directory = directory
        for name in ("Developer-ID-Application.cert.pem", "Developer-ID-Application.key.pem",
                     "DeveloperIDG2CA.cer", "Mac-DeveloperID.provisionprofile"):
            if not (directory / name).is_file():
                raise SigningError(f"Missing signing material: {directory / name}")
        self.certificate = run(["openssl", "x509", "-in", str(directory / "Developer-ID-Application.cert.pem"),
                                "-outform", "DER"])
        run(["openssl", "x509", "-in", str(directory / "Developer-ID-Application.cert.pem"), "-checkend", "0", "-noout"])
        subject = run(["openssl", "x509", "-in", str(directory / "Developer-ID-Application.cert.pem"),
                       "-noout", "-subject"]).decode()
        if "Developer ID Application:" not in subject:
            raise SigningError("Expected a Developer ID Application certificate")
        public_certificate = run(["openssl", "x509", "-in", str(directory / "Developer-ID-Application.cert.pem"),
                                  "-pubkey", "-noout"])
        public_key = run(["openssl", "pkey", "-in", str(directory / "Developer-ID-Application.key.pem"),
                          "-pubout", "-passin", "pass:"])
        if public_certificate.strip() != public_key.strip():
            raise SigningError("Saved private key does not match the Developer ID certificate")
        self.profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(directory / "Mac-DeveloperID.provisionprofile")]))
        self.team = validate_profile(self.profile, self.certificate)
        self.identity = hashlib.sha1(self.certificate).hexdigest().upper()
        self.notary_args = []
        if not require_notarization:
            return
        config_path = Path(os.environ.get("NEOANKI_NOTARY_CONFIG", directory / "app-store-connect.json"))
        if not config_path.is_file():
            raise SigningError(f"Missing notarization API configuration: {config_path}")
        config = json.loads(config_path.read_text())
        if not all(config.get(k) for k in ("key_id", "issuer_id", "private_key_path")):
            raise SigningError("Notarization configuration requires key_id, issuer_id, and private_key_path")
        if config.get("team_id", self.team) != self.team:
            raise SigningError("Notarization configuration names a different Apple team")
        key_path = Path(config["private_key_path"]).expanduser()
        if not key_path.is_file():
            raise SigningError("Notarization API private key is missing")
        self.notary_args = ["--key", str(key_path), "--key-id", config["key_id"], "--issuer", config["issuer_id"]]


@contextlib.contextmanager
def signing_keychain(material):
    with tempfile.TemporaryDirectory(prefix="neoanki-mac-signing-") as directory:
        folder = Path(directory)
        keychain = folder / "signing.keychain-db"
        password = secrets.token_hex(32)
        passfile = folder / "password"
        passfile.write_text(password)
        passfile.chmod(0o600)
        p12 = folder / "identity.p12"
        created = False
        try:
            run(["openssl", "pkcs12", "-export", "-inkey", str(material.directory / "Developer-ID-Application.key.pem"),
                 "-in", str(material.directory / "Developer-ID-Application.cert.pem"), "-out", str(p12),
                 "-passout", "file:" + str(passfile), "-passin", "pass:"])
            p12.chmod(0o600)
            run(["security", "create-keychain", "-p", password, str(keychain)])
            created = True
            run(["security", "unlock-keychain", "-p", password, str(keychain)])
            run(["security", "import", str(p12), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign"])
            run(["security", "import", str(material.directory / "DeveloperIDG2CA.cer"), "-k", str(keychain)])
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, str(keychain)])
            yield keychain, folder
        finally:
            # Preserve concurrent search-list changes, removing only our entry.
            if created or keychain.exists():
                try:
                    run(["security", "delete-keychain", str(keychain)])
                finally:
                    current = re.findall(r'"([^"]+)"', run(["security", "list-keychains", "-d", "user"]).decode())
                    remaining = [p for p in current if p != str(keychain)]
                    if remaining != current:
                        run(["security", "list-keychains", "-d", "user", "-s", *remaining])
            print("MAC_SIGNING_CLEANUP=complete", flush=True)


def verify(app, require_notarization=True):
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    details = subprocess.run(["codesign", "-d", "--verbose=4", str(app)], capture_output=True, check=True).stderr.decode()
    if "Authority=Developer ID Application:" not in details or "runtime" not in details:
        raise SigningError("App must have a Developer ID signature with hardened runtime")
    profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(app / "Contents/embedded.provisionprofile")]))
    team = validate_profile(profile)
    if f"TeamIdentifier={team}" not in details:
        raise SigningError("App signature and provisioning profile have different teams")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != APP_ID or not info.get("NeoAnkiGitRevision"):
        raise SigningError("Signed app lacks the NeoAnki2 bundle identifier or source revision")
    signed = plistlib.loads(run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)]))
    validate_entitlements(signed, team)
    if require_notarization:
        run(["xcrun", "stapler", "validate", str(app)])
        run(["spctl", "--assess", "--type", "execute", str(app)])
    notarization = "notarized" if require_notarization else "local source build"
    print(f"MAC_SIGNING_VERIFIED=Developer ID; production CloudKit; {notarization}; team {team}", flush=True)


def sign(app, material, require_notarization=True):
    receipt_path = app.parent / "notarization.json"
    receipt_path.unlink(missing_ok=True)
    shutil.copy2(material.directory / "Mac-DeveloperID.provisionprofile", app / "Contents/embedded.provisionprofile")
    with signing_keychain(material) as (keychain, folder):
        entitlements = folder / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps(entitlements_for(material.team)))
        run(["codesign", "--force", "--sign", material.identity, "--keychain", str(keychain),
             "--options", "runtime", "--timestamp", "--entitlements", str(entitlements), str(app)], timeout=120)
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    if not require_notarization:
        verify(app, require_notarization=False)
        return
    # Keep the notarization receipt beside the staged app, including on failure.
    archive = app.parent / "NeoAnki2-notarization.zip"
    run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)])
    print("MAC_SIGNING_PHASE=notarization", flush=True)
    timeout = int(os.environ.get("NEOANKI_NOTARY_TIMEOUT_SECONDS", "180"))
    try:
        receipt = json.loads(run(["xcrun", "notarytool", "submit", str(archive), *material.notary_args,
                                  "--no-wait", "--output-format", "json"], timeout=120))
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"MAC_SIGNING_NOTARY_ID={receipt.get('id', 'unknown')}", flush=True)
        if not receipt.get("id"):
            raise SigningError("Apple did not return a notarization submission identifier")
        if receipt.get("status") not in ("Accepted", "Invalid", "Rejected"):
            # Persist the identifier before waiting, so timeout/failure can be
            # inspected without uploading the same app again.
            waited = json.loads(run(["xcrun", "notarytool", "wait", receipt["id"], *material.notary_args,
                                     "--timeout", f"{timeout}s", "--output-format", "json"], timeout=timeout + 30))
            receipt.update(waited)
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        if receipt.get("status") != "Accepted":
            if receipt.get("id"):
                run(["xcrun", "notarytool", "log", receipt["id"], *material.notary_args,
                     str(app.parent / "notarization-log.json")])
            raise SigningError("Apple did not accept notarization; see the staged notarization receipt/log")
        run(["xcrun", "stapler", "staple", str(app)])
        verify(app)
    finally:
        archive.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path)
    parser.add_argument("--check", action="store_true", help="Validate saved signing inputs without building")
    parser.add_argument("--verify", action="store_true", help="Verify an already notarized bundle")
    parser.add_argument("--sign-only", action="store_true", help="Local source build: require real signing, without notarization")
    args = parser.parse_args()
    try:
        if args.verify:
            if not args.app:
                parser.error("--verify requires an app path")
            verify(args.app.resolve(), require_notarization=not args.sign_only)
        else:
            material = Material(Path(os.environ.get("NEOANKI_SIGNING_DIR", DEFAULT_SIGNING)).expanduser(),
                                require_notarization=not args.sign_only)
            if args.check:
                print(f"MAC_SIGNING_INPUTS=ready; team {material.team}")
            elif args.app:
                sign(args.app.resolve(), material, require_notarization=not args.sign_only)
            else:
                parser.error("an app path or --check is required")
        return 0
    except (SigningError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Mac signing failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
