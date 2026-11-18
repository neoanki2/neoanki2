#!/usr/bin/env python3
"""Verify study→edit→save with an independently proven held OS publisher.

Only a uniquely named disposable Simulator is used. The nonce-matched armed and
held receipts are copied and validated before that Simulator is always deleted.
An inactive fixture or skipped test cannot pass, even when XCTest exits zero.
"""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import sqlite3
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
TEST = "NeoAnki2MobileUITests/MobileCardJourneyUITests/testSaveFromStudyEditorDismissesAndPersistsTheCorrection"
BUNDLE = "com.neoanki2.ios"
FIELD = "A2000001-0002-4000-8000-000000000001"


def validate_receipts(armed, held, nonce, persisted):
    """Pure validation shared by the real runner and hermetic harness tests."""
    canonical = str(uuid.UUID(nonce)).upper()
    if not armed or not held:
        raise ValueError("EDITOR_FIXTURE_PROOF: missing armed or held receipt")
    for receipt, phase in [(armed, "armed"), (held, "held")]:
        if receipt.get("version") != 1 or receipt.get("nonce") != canonical or receipt.get("phase") != phase:
            raise ValueError("EDITOR_FIXTURE_PROOF: wrong fixture version, nonce, or phase")
        if receipt.get("fieldID", "").upper() != FIELD:
            raise ValueError("EDITOR_FIXTURE_PROOF: wrong watched field")
    prompt = "Original study question " + canonical
    original = "Original answer"
    if any(r.get("originalText") != original or r.get("originalPrompt") != prompt for r in [armed, held]):
        raise ValueError("EDITOR_FIXTURE_PROOF: wrong initial draft")
    item_id = str(uuid.UUID(held.get("itemID", ""))).upper()
    observed = held.get("observedText")
    if not isinstance(observed, str) or observed == original or "corrected" not in observed:
        raise ValueError("EDITOR_FIXTURE_PROOF: gate did not observe the correction")
    if persisted.get("itemID", "").upper() != item_id or persisted.get("text") != observed:
        raise ValueError("EDITOR_FIXTURE_PROOF: held receipt does not match durable item content")
    return {"nonce": canonical, "itemID": item_id, "armed": True, "held": True, "durableCorrection": True}


def command(argv, log, timeout=900):
    with log.open("wb") as output:
        process = subprocess.Popen(argv, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.wait()
            raise
    if code:
        raise RuntimeError(f"Command failed ({code}); inspect {log}")


def json_command(argv):
    return json.loads(subprocess.check_output(argv, cwd=ROOT, timeout=60))


def source_fingerprint():
    paths = subprocess.check_output(["git", "ls-files", "-c", "-o", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
    digest = hashlib.sha256()
    for name in sorted(set(paths)):
        if not name or (name.split("/", 1)[0] not in {"Sources", "Platforms", "NeoAnkiCore", "Xcode"} and name != "Package.swift"):
            continue
        path = ROOT / name
        digest.update(name.encode() + b"\0")
        digest.update(path.read_bytes() if path.is_file() else b"<removed>")
    return digest.hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new or empty evidence directory")
    parser.add_argument("--device", default="iPhone 17 Pro", help="disposable Simulator device type")
    args = parser.parse_args(argv)
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()): parser.error("Existing evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    derived = output / "derived-data"
    nonce = str(uuid.uuid4()).upper()
    report = {"schemaVersion": 1, "nonce": nonce, "status": "running", "test": TEST,
              "startedAt": dt.datetime.now(dt.timezone.utc).isoformat()}
    report_path = output / "report.json"
    def save(): report_path.write_text(json.dumps(report, indent=2) + "\n")
    report["sourceSHA256"] = source_fingerprint()
    report["runnerSHA256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    save()
    device = None
    temporary_run = None
    try:
        command(["xcodebuild", "build-for-testing", "-quiet", "-project", "Xcode/NeoAnkiiOS.xcodeproj",
            "-scheme", "NeoAnki2MobileUITests", "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "COPY_PHASE_STRIP=NO",
            "STRIP_INSTALLED_PRODUCT=NO", "SWIFT_ENABLE_EXPLICIT_MODULES=NO", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"],
            output / "build.log")
        products = derived / "Build/Products"
        runs = list(products.glob("*-arm64.xctestrun")) or list(products.glob("*.xctestrun"))
        if len(runs) != 1: raise RuntimeError("Expected exactly one generated XCTest configuration")
        configuration = plistlib.loads(runs[0].read_bytes())
        for config in configuration["TestConfigurations"]:
            for target in config["TestTargets"]:
                target.setdefault("EnvironmentVariables", {})["NEOANKI_EDITOR_GATE_NONCE"] = nonce
        temporary_run = products / ("Editor-Gate-" + nonce + ".xctestrun")
        temporary_run.write_bytes(plistlib.dumps(configuration))
        runtimes = json_command(["xcrun", "simctl", "list", "runtimes", "-j"])["runtimes"]
        eligible = [r for r in runtimes if r.get("isAvailable") and "SimRuntime.iOS-" in r["identifier"]]
        if not eligible: raise RuntimeError("No available iOS Simulator runtime")
        runtime = max(eligible, key=lambda r: tuple(int(p) for p in r["version"].split(".")))["identifier"]
        types = json_command(["xcrun", "simctl", "list", "devicetypes", "-j"])["devicetypes"]
        device_type = next((t["identifier"] for t in types if t["name"] == args.device), None)
        if not device_type: raise RuntimeError("Unavailable device type: " + args.device)
        device = subprocess.check_output(["xcrun", "simctl", "create", "NeoAnki-EditorContract-" + nonce[:8], device_type, runtime], text=True, timeout=60).strip()
        report["device"] = device; save()
        command(["xcrun", "simctl", "boot", device], output / "boot.log", 60)
        command(["xcrun", "simctl", "bootstatus", device, "-b"], output / "bootstatus.log", 300)
        result = output / "journey.xcresult"
        test_error = None
        try:
            command(["xcodebuild", "test-without-building", "-quiet", "-xctestrun", str(temporary_run),
                "-destination", "platform=iOS Simulator,arch=arm64,id=" + device,
                "-parallel-testing-enabled", "NO", "-only-testing:" + TEST,
                "-resultBundlePath", str(result), "CODE_SIGNING_ALLOWED=NO"], output / "test.log", 600)
        except RuntimeError as error: test_error = str(error)
        # Copy proof even for an assertion failure; never credit a disabled gate.
        container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", device, BUNDLE, "data"], text=True, timeout=60).strip())
        receipts = {}
        for phase in ["armed", "held"]:
            source = container / "Library/Caches/neoanki-editor-gate" / (nonce + "-" + phase + ".json")
            if source.is_file():
                raw = source.read_bytes(); (output / (phase + ".json")).write_bytes(raw)
                receipts[phase] = json.loads(raw)
        persisted = {}
        if receipts.get("held", {}).get("itemID"):
            database = container / "Library/Application Support/neoanki2/neoanki2.sqlite"
            with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
                row = connection.execute("SELECT fields FROM items WHERE id = ?", (receipts["held"]["itemID"],)).fetchone()
            if row:
                fields = json.loads(row[0])
                value = next((f["value"] for f in fields if f["fieldID"].upper() == FIELD), {})
                persisted = {"itemID": receipts["held"]["itemID"], "text": value.get("text", {}).get("_0")}
        summary = json_command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result), "--compact"])
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        report["fixture"] = validate_receipts(receipts.get("armed"), receipts.get("held"), nonce, persisted)
        if test_error: raise RuntimeError(test_error)
        if summary.get("totalTestCount") != 1 or summary.get("passedTests") != 1 or summary.get("skippedTests") != 0:
            raise RuntimeError("The selected real UI journey did not execute and pass exactly once")
        if source_fingerprint() != report["sourceSHA256"]:
            raise RuntimeError("Source changed during the UI verification; settle edits before qualifying it")
        report["status"] = "passed"
    except KeyboardInterrupt:
        report.update(status="failed", error="Verification interrupted")
    except Exception as error:
        report.update(status="failed", error=str(error))
    finally:
        if device:
            try:
                subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, timeout=60)
            except Exception as error:
                report["shutdownError"] = str(error)
            try:
                deleted = subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, timeout=60)
                report["simulatorDeleted"] = deleted.returncode == 0
                if deleted.returncode: raise RuntimeError("Disposable Simulator deletion failed")
            except Exception as error:
                report.update(status="failed", cleanupError=str(error))
        try:
            if temporary_run and temporary_run.exists(): temporary_run.unlink()
        except Exception as error:
            report.update(status="failed", configurationCleanupError=str(error))
        report["completedAt"] = dt.datetime.now(dt.timezone.utc).isoformat(); save()
    print("EDITOR_UI_CONTRACT_REPORT=" + str(report_path))
    if report.get("error"): print(report["error"], file=sys.stderr)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    def interrupt(_signal, _frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupt)
    raise SystemExit(main())
