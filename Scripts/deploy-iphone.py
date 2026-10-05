#!/usr/bin/env python3
"""Local Release build → disposable signing Keychain → in-place iPhone update."""
import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "com.neoanki2.ios"
WIDGET_ID = APP_ID + ".widget"


class DeploymentError(Exception):
    pass


def select_device(devices, requested=None):
    candidates = [d for d in devices
                  if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
                  and d.get("hardwareProperties", {}).get("reality") == "physical"
                  and d.get("connectionProperties", {}).get("pairingState") == "paired"
                  and (d.get("connectionProperties", {}).get("tunnelState") == "connected"
                       or d.get("connectionProperties", {}).get("transportType") == "wired")]
    if requested:
        candidates = [d for d in candidates if requested in (
            d["identifier"], d.get("deviceProperties", {}).get("name"),
            d.get("hardwareProperties", {}).get("udid"))]
    if not candidates:
        raise DeploymentError("No available paired iPhone. Connect/unlock the target phone" +
                              (f" ({requested})." if requested else "."))
    if len(candidates) != 1:
        names = ", ".join(d["deviceProperties"]["name"] for d in candidates)
        raise DeploymentError(f"Multiple iPhones available: {names}. Select one with --device.")
    device = candidates[0]
    if device.get("deviceProperties", {}).get("developerModeStatus") != "enabled":
        raise DeploymentError("Enable Developer Mode on the selected iPhone.")
    return device


def validate_profile(profile, bundle_id, udid, certificate_der, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime) or expiry.replace(tzinfo=dt.timezone.utc) <= now:
        raise DeploymentError(f"Expired or missing {bundle_id} provisioning profile.")
    teams = profile.get("TeamIdentifier", [])
    if len(teams) != 1:
        raise DeploymentError(f"Invalid signing team in {bundle_id} profile.")
    team = teams[0]
    ent = profile.get("Entitlements", {})
    if ent.get("application-identifier") != team + "." + bundle_id:
        raise DeploymentError(f"Provisioning profile does not match {bundle_id}.")
    if ent.get("com.apple.developer.team-identifier") != team:
        raise DeploymentError(f"Provisioning profile team mismatch for {bundle_id}.")
    if udid not in profile.get("ProvisionedDevices", []):
        raise DeploymentError(f"Selected iPhone is not registered in {bundle_id} profile.")
    if certificate_der not in profile.get("DeveloperCertificates", []):
        raise DeploymentError(f"Saved distribution certificate is not in {bundle_id} profile.")
    if ent.get("get-task-allow") is not False:
        raise DeploymentError(f"Expected an Ad Hoc distribution profile for {bundle_id}.")
    return team


def make_entitlements(source, profile, team, bundle_id):
    ent = dict(source)
    ent.update({"application-identifier": team + "." + bundle_id,
                "com.apple.developer.team-identifier": team,
                "get-task-allow": False,
                "keychain-access-groups": [team + "." + bundle_id]})
    allowed = profile["Entitlements"]
    groups = ent.get("com.apple.security.application-groups", [])
    if not set(groups).issubset(allowed.get("com.apple.security.application-groups", [])):
        raise DeploymentError(f"App Group is missing from {bundle_id} profile.")
    if bundle_id == APP_ID:
        if allowed.get("aps-environment") != "production":
            raise DeploymentError("App profile does not support production push notifications.")
        if "Production" not in allowed.get("com.apple.developer.icloud-container-environment", []):
            raise DeploymentError("App profile does not support Production CloudKit.")
        containers = ent.get("com.apple.developer.icloud-container-identifiers", [])
        if not set(containers).issubset(allowed.get("com.apple.developer.icloud-container-identifiers", [])):
            raise DeploymentError("CloudKit container is missing from the app profile.")
        services = allowed.get("com.apple.developer.icloud-services", [])
        if services != "*" and "CloudKit" not in services:
            raise DeploymentError("App profile does not support CloudKit.")
        ent["aps-environment"] = "production"
        ent["com.apple.developer.icloud-container-environment"] = "Production"
        ent["com.apple.developer.ubiquity-kvstore-identifier"] = team + "." + APP_ID
    return ent


def validate_receipt(data, device_id, kind):
    if data.get("info", {}).get("outcome") != "success":
        raise DeploymentError(f"{kind} did not return a successful receipt.")
    result = data.get("result", {})
    if result.get("deviceIdentifier") != device_id:
        raise DeploymentError(f"{kind} receipt names a different device.")
    if kind == "Install":
        apps = result.get("installedApplications", [])
        if len(apps) != 1 or apps[0].get("bundleID") != APP_ID:
            raise DeploymentError("Install receipt does not identify NeoAnki2.")
    else:
        process = result.get("process", {})
        if not process.get("processIdentifier") or not process.get("executable", "").endswith("/NeoAnki2.app/NeoAnki2"):
            raise DeploymentError("Launch receipt does not identify the NeoAnki2 process.")
    return result


class Workflow:
    def __init__(self, output):
        self.output = output
        self.phase = "preflight"
        self.started = time.monotonic()
        self.passwords = []

    def redact(self, text):
        for secret in self.passwords:
            text = text.replace(secret, "[redacted]")
        return text

    def run(self, args, timeout=30, log=None):
        # Never log complete argv: temporary Keychain commands contain a secret.
        try:
            if log:
                with log.open("wb") as stream:
                    r = subprocess.run(args, cwd=ROOT, stdin=subprocess.DEVNULL,
                                       stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
                if r.returncode:
                    raise DeploymentError(f"{self.phase} failed; see {log}.")
                return b""
            r = subprocess.run(args, cwd=ROOT, stdin=subprocess.DEVNULL,
                               capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise DeploymentError(f"{self.phase}: {args[0]} timed out.") from None
        if r.returncode:
            detail = self.redact(r.stderr.decode(errors="replace").strip())
            raise DeploymentError(f"{self.phase}: {args[0]} failed: {detail}")
        return r.stdout

    def device_command(self, name, args, timeout=30):
        path = self.output / (name + ".json")
        self.run(["xcrun", "devicectl", *args, "--json-output", str(path),
                  "--quiet", "--timeout", str(timeout)], timeout=timeout + 5)
        data = json.loads(path.read_text())
        if data.get("info", {}).get("outcome") != "success":
            raise DeploymentError(f"{self.phase}: devicectl did not return success.")
        return data

    def mark(self, phase):
        self.phase = phase
        print(f"IPHONE_DEPLOY_PHASE={phase}", flush=True)

    @contextlib.contextmanager
    def signing_keychain(self, signing):
        self.mark("sign")
        password = secrets.token_hex(32)
        self.passwords.append(password)
        with tempfile.TemporaryDirectory(prefix="neoanki-iphone-signing-") as directory:
            folder = Path(directory)
            keychain = folder / "signing.keychain-db"
            passfile = folder / "password"
            passfile.write_text(password)
            passfile.chmod(0o600)
            p12 = folder / "identity.p12"
            created = False
            try:
                self.run(["openssl", "pkcs12", "-export", "-inkey", str(signing / "Apple-Distribution.key.pem"),
                          "-in", str(signing / "Apple-Distribution.cert.pem"), "-out", str(p12),
                          "-passout", "file:" + str(passfile), "-passin", "pass:"])
                p12.chmod(0o600)
                self.run(["security", "create-keychain", "-p", password, str(keychain)])
                created = True
                self.run(["security", "unlock-keychain", "-p", password, str(keychain)])
                self.run(["security", "import", str(p12), "-k", str(keychain), "-P", password,
                          "-T", "/usr/bin/codesign"])
                self.run(["security", "import", str(signing / "AppleWWDRCAG3.cer"), "-k", str(keychain)])
                self.run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:",
                          "-s", "-k", password, str(keychain)])
                yield keychain
            finally:
                # Preserve any concurrent search-list changes; remove only our entry.
                cleanup_errors = []
                if created or keychain.exists():
                    try:
                        self.run(["security", "delete-keychain", str(keychain)])
                    except DeploymentError as error:
                        cleanup_errors.append(str(error))
                try:
                    current = re.findall(r'"([^"]+)"', self.run(["security", "list-keychains", "-d", "user"]).decode())
                    remaining = [p for p in current if p != str(keychain)]
                    if remaining != current:
                        self.run(["security", "list-keychains", "-d", "user", "-s", *remaining])
                except DeploymentError as error:
                    cleanup_errors.append(str(error))
                if cleanup_errors:
                    raise DeploymentError("Temporary signing cleanup failed: " + "; ".join(cleanup_errors))
                print("IPHONE_DEPLOY_SIGNING_CLEANUP=complete", flush=True)

    def execute(self, args):
        signing = args.signing_dir.expanduser().resolve()
        for name in ("Apple-Distribution.cert.pem", "Apple-Distribution.key.pem", "AppleWWDRCAG3.cer",
                     "iOS-AdHoc.mobileprovision", "Widget-AdHoc.mobileprovision"):
            if not (signing / name).is_file():
                raise DeploymentError(f"Missing signing material: {signing / name}.")
        devices = self.device_command("devices", ["list", "devices"])["result"]["devices"]
        device = select_device(devices, args.device)
        device_id = device["identifier"]
        udid = device["hardwareProperties"]["udid"]
        name = device["deviceProperties"]["name"]
        print(f"IPHONE_DEPLOY_DEVICE={name}", flush=True)
        certificate = self.run(["openssl", "x509", "-in", str(signing / "Apple-Distribution.cert.pem"), "-outform", "DER"])
        self.run(["openssl", "x509", "-in", str(signing / "Apple-Distribution.cert.pem"), "-checkend", "0", "-noout"])
        identity = hashlib.sha1(certificate).hexdigest().upper()
        profiles = {}
        teams = []
        for kind, file, bundle in (("app", "iOS-AdHoc.mobileprovision", APP_ID),
                                   ("widget", "Widget-AdHoc.mobileprovision", WIDGET_ID)):
            profiles[kind] = plistlib.loads(self.run(["security", "cms", "-D", "-i", str(signing / file)]))
            teams.append(validate_profile(profiles[kind], bundle, udid, certificate))
        if teams[0] != teams[1]:
            raise DeploymentError("App and widget profiles have different teams.")
        team = teams[0]
        entitlements = {}
        for kind, file, bundle in (("app", "Platforms/iOS/NeoAnki2.entitlements", APP_ID),
                                   ("widget", "Platforms/iOSWidget/NeoAnkiWidget.entitlements", WIDGET_ID)):
            source = plistlib.loads((ROOT / file).read_bytes())
            entitlements[kind] = make_entitlements(source, profiles[kind], team, bundle)
            (self.output / (kind + "-entitlements.plist")).write_bytes(plistlib.dumps(entitlements[kind]))
        self.mark("build")
        derived = ROOT / ".build/xcode-products/iPhoneDeploy"
        self.run(["xcodebuild", "build", "-quiet", "-project", str(ROOT / "Xcode/NeoAnkiiOS.xcodeproj"),
                  "-scheme", "NeoAnkiiOS", "-configuration", "Release", "-destination", "generic/platform=iOS",
                  "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "SWIFT_ENABLE_EXPLICIT_MODULES=NO"],
                 timeout=900, log=self.output / "build.log")
        app = self.output / "NeoAnki2.app"
        shutil.copytree(derived / "Build/Products/Release-iphoneos/NeoAnki2.app", app)
        targets = [("widget", app / "PlugIns/NeoAnki2Widget.appex", "Widget-AdHoc.mobileprovision", WIDGET_ID),
                   ("app", app, "iOS-AdHoc.mobileprovision", APP_ID)]
        with self.signing_keychain(signing) as keychain:
            for framework in sorted((app / "Frameworks").glob("*")):
                self.run(["codesign", "--force", "--keychain", str(keychain), "--sign", identity,
                          "--timestamp=none", str(framework)])
            for kind, path, profile_file, bundle in targets:
                info = plistlib.loads((path / "Info.plist").read_bytes())
                if info.get("CFBundleIdentifier") != bundle:
                    raise DeploymentError(f"Built product does not match {bundle}.")
                shutil.copy2(signing / profile_file, path / "embedded.mobileprovision")
                self.run(["codesign", "--force", "--keychain", str(keychain), "--sign", identity,
                          "--entitlements", str(self.output / (kind + "-entitlements.plist")),
                          "--timestamp=none", str(path)])
                self.run(["codesign", "--verify", "--strict", "--verbose=2", str(path)])
                raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(path)], capture_output=True)
                xml = raw.stdout + raw.stderr
                start = xml.find(b"<?xml")
                end = xml.find(b"</plist>", start)
                if raw.returncode or start < 0 or end < 0 or plistlib.loads(xml[start:end + 8]) != entitlements[kind]:
                    raise DeploymentError(f"Signed entitlements do not match {bundle}.")
        info = plistlib.loads((app / "Info.plist").read_bytes())
        receipt = {"device": name, "deviceIdentifier": device_id, "bundleIdentifier": APP_ID,
                   "configuration": "Release", "version": info["CFBundleShortVersionString"],
                   "build": info["CFBundleVersion"], "team": team, "cloudKitEnvironment": "Production",
                   "executableSHA256": hashlib.sha256((app / "NeoAnki2").read_bytes()).hexdigest(),
                   "installed": False, "launched": False, "temporarySigningKeychainRemoved": True}
        receipt_path = self.output / "deployment.json"
        def save():
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        save()
        if not args.prepare_only:
            self.mark("install")
            data = self.device_command("install", ["device", "install", "app", "--device", device_id, str(app)], 60)
            validate_receipt(data, device_id, "Install")
            receipt["installed"] = True
            save()
            self.mark("launch")
            data = self.device_command("launch", ["device", "process", "launch", "--device", device_id, APP_ID])
            launched = validate_receipt(data, device_id, "Launch")
            receipt.update(launched=True, processIdentifier=launched["process"]["processIdentifier"])
            save()
        self.mark("complete")
        print(f"IPHONE_DEPLOY_STATUS={'prepared' if args.prepare_only else 'installed_and_launched'}")
        print(f"IPHONE_DEPLOY_RECEIPT={receipt_path}")
        print(f"IPHONE_DEPLOY_ELAPSED_SECONDS={time.monotonic() - self.started:.1f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="paired iPhone name, CoreDevice identifier, or UDID")
    parser.add_argument("--prepare-only", action="store_true", help="build/sign without install or launch")
    parser.add_argument("--signing-dir", type=Path,
                        default=Path.home() / "Library/Application Support/NeoAnki2 Signing")
    args = parser.parse_args()
    base = ROOT / ".build/iphone-deploy"
    base.mkdir(parents=True, exist_ok=True)
    with (base / "workflow.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("IPHONE_DEPLOY_ERROR=Another deployment is already running.", file=sys.stderr)
            return 1
        output = base / (dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
        output.mkdir()
        flow = Workflow(output)
        # Raise through context managers so interruption cleans up signing secrets.
        signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
        try:
            flow.execute(args)
        except (DeploymentError, OSError, ValueError, KeyError, KeyboardInterrupt) as error:
            message = "Interrupted" if isinstance(error, KeyboardInterrupt) else flow.redact(str(error))
            print(f"IPHONE_DEPLOY_BLOCKED_PHASE={flow.phase}", file=sys.stderr)
            print(f"IPHONE_DEPLOY_ERROR={message}", file=sys.stderr)
            print(f"IPHONE_DEPLOY_ARTIFACTS={output}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
