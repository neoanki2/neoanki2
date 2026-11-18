#!/usr/bin/env python3
"""Qualify editor contracts against known defects in an isolated dirty snapshot.

Default qualification is headless. --with-simulator additionally proves that
disabling the nonce-scoped OS fixture is rejected even when the UI journey passes.
The live checkout is never mutated; build errors/timeouts are never mutant kills.
"""
from __future__ import annotations
import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
# The child may spend 5s stopping xcodebuild, then 60s each shutting down and
# deleting its disposable Simulator. Reap it only after that cleanup budget.
UI_RUNNER_TERMINATION_GRACE_SECONDS = 150
SPEC = importlib.util.spec_from_file_location("editor_qualification_support", Path(__file__).with_name("check-sync-test-sensitivity.py"))
support = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = support
SPEC.loader.exec_module(support)

MUTANTS = (
    support.Mutant("fixed-native-document", "Remove the supported native document sizing policy.",
        "nativeEditorDrawsGlyphsInsideViewport", ("EDITOR_NATIVE_LAYOUT", "EDITOR_VISIBLE_GLYPHS"), (
            support.Edit("Sources/NeoAnkiTextEditing/NativeTextEditorPolicy.swift",
                "        textView.isVerticallyResizable = true\n", "        textView.isVerticallyResizable = false\n"),
            support.Edit("Sources/NeoAnkiTextEditing/NativeTextEditorPolicy.swift",
                "        textView.autoresizingMask = [.width]\n", "        textView.autoresizingMask = []\n"))),
    support.Mutant("stale-native-binding", "Keep the native coordinator attached to the previous draft binding.",
        "replacingAnEditorBindingRoutesNativeChangesOnlyToTheNewDraft", ("EDITOR_BINDING_TARGET",), (
            support.Edit("Sources/NeoAnki2/RichTextFieldEditor.swift",
                "        coordinator.updateBindings(spans: $spans, isFocused: isFocused, selectionFormatting: $selectionFormatting)\n",
                "        // Mutant: retain the old draft binding.\n"),)),
    support.Mutant("await-device-before-completion", "Restore an OS barrier after the durable item edit.",
        "editingFromStudyFinishesBeforeDevicePublication", ("EDITOR_COMMIT_BOUNDARY",), (
            support.Edit("Sources/NeoAnkiFeatures/LibraryFeatureModel.swift",
                "        didMutate()\n        return updated\n    }\n\n    public func moveItems",
                "        didMutate()\n        await awaitDevicePublication()\n        return updated\n    }\n\n    public func moveItems"),)),
    support.Mutant("inactive-simulator-fixture", "Compile/use the ordinary publisher instead of the held fixture.",
        "simulator-fixture-proof", ("EDITOR_FIXTURE_PROOF",), (
            support.Edit("Platforms/iOS/NeoAnkiIOSApp.swift",
                'ProcessInfo.processInfo.environment["NEOANKI_TEST_HOLD_EDIT_BADGE"] == "1",',
                'ProcessInfo.processInfo.environment["NEOANKI_TEST_HOLD_EDIT_BADGE"] == "disabled",'),)),
)
BY_NAME = {m.name: m for m in MUTANTS}


def ui_classification(result, report, summary, mutant=False):
    if result.get("timedOut") or result.get("exitCode") is None:
        return "inconclusive", "UI process did not complete normally"
    executed = summary.get("totalTestCount") == 1 and summary.get("passedTests") == 1 and summary.get("skippedTests") == 0
    if mutant:
        if executed and result["exitCode"] != 0 and "EDITOR_FIXTURE_PROOF" in report.get("error", "") and report.get("simulatorDeleted"):
            return "killed", "Passing real journey was rejected because fixture activation proof was missing"
        if result["exitCode"] == 0: return "survived", "Disabled fixture was credited as a passing verification"
        return "inconclusive", "Failure did not prove the executed journey rejected missing fixture evidence"
    if result["exitCode"] == 0 and executed and report.get("status") == "passed" and report.get("fixture", {}).get("held") and report.get("simulatorDeleted"):
        return "passed", "Real journey and nonce-scoped held fixture were independently verified"
    return "failed", "Simulator baseline did not pass with active fixture proof"


def read_json(path):
    return json.loads(path.read_text()) if path.is_file() else {}


def terminate_ui_runner(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=UI_RUNNER_TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def interrupt(_signal, _frame):
    # Default SIGTERM exits without finally blocks, orphaning the child runner.
    raise KeyboardInterrupt()


def run_ui(source, destination, timeout):
    import time
    command = [sys.executable, str(source / "Scripts/run-editor-save-ui.py"), "--output", str(destination / "ui")]
    environment = {k: v for k, v in os.environ.items() if not k.startswith("NEOANKI_EDITOR_GATE_")}
    result = {"command": command, "timedOut": False}
    started = time.monotonic()
    with (destination / "test.log").open("wb") as log:
        process = subprocess.Popen(command, cwd=source, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try: result["exitCode"] = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            result["timedOut"] = True
            terminate_ui_runner(process)
            result["exitCode"] = process.returncode
        except BaseException:
            terminate_ui_runner(process)
            raise
    result["elapsedSeconds"] = round(time.monotonic() - started, 3)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--mutant", action="append", choices=BY_NAME)
    parser.add_argument("--with-simulator", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    args = parser.parse_args(argv)
    selected = [m for m in MUTANTS if (not args.mutant or m.name in args.mutant)
                and (args.with_simulator or m.name != "inactive-simulator-fixture")]
    if args.mutant and "inactive-simulator-fixture" in args.mutant and not args.with_simulator:
        parser.error("The fixture mutant requires --with-simulator")
    if args.list:
        for mutant in selected: print(mutant.name + "\t" + mutant.description)
        return 0
    if args.timeout_seconds <= 0: parser.error("Timeout must be positive")
    output = (args.output or ROOT / ".build/editor-sensitivity" /
        (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])).resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())): parser.error("Existing evidence is never overwritten")
    if output == ROOT or ROOT / ".git" in [output, *output.parents]: parser.error("Output must not be the source or Git metadata")
    try:
        relative = output.relative_to(ROOT)
        if not relative.parts or relative.parts[0] != ".build": parser.error("Checkout-local evidence must be under .build")
    except ValueError: pass
    output.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="neoanki-editor-sensitivity-"))
    source, cache = temporary / "source", temporary / "swift-build"
    report = {"schemaVersion": 1, "status": "running", "selected": [m.name for m in selected], "mutants": {}}
    def save(): support.save_json(output / "report.json", report)
    save(); code = 2
    try:
        report["snapshot"] = support.snapshot(source, output)
        swift_mutants = [m for m in selected if m.name != "inactive-simulator-fixture"]
        if swift_mutants:
            baseline_dir = output / "baseline"; baseline_dir.mkdir()
            baseline = support.run_tests(source, cache, baseline_dir, "|".join(m.test for m in swift_mutants), args.timeout_seconds)
            status, reason = support.classify(baseline, (baseline_dir / "test.log").read_text(errors="replace"), None, {m.test for m in swift_mutants})
            baseline.update(status=status, reason=reason); report["baseline"] = baseline; save()
            if status != "passed": raise RuntimeError("Headless baseline: " + reason)
        if any(m.name == "inactive-simulator-fixture" for m in selected):
            destination = output / "baseline-simulator"; destination.mkdir()
            baseline = run_ui(source, destination, max(args.timeout_seconds, 1800))
            status, reason = ui_classification(baseline, read_json(destination / "ui/report.json"), read_json(destination / "ui/summary.json"))
            baseline.update(status=status, reason=reason); report["baselineSimulator"] = baseline; save()
            if status != "passed": raise RuntimeError(reason)
        for mutant in selected:
            destination = output / mutant.name; destination.mkdir()
            result = {"status": "inconclusive", "test": mutant.test, "markers": list(mutant.markers)}
            originals = {}
            try:
                originals = support.apply_mutant(source, mutant, destination)
                if mutant.name == "inactive-simulator-fixture":
                    result.update(run_ui(source, destination, max(args.timeout_seconds, 1800)))
                    status, reason = ui_classification(result, read_json(destination / "ui/report.json"), read_json(destination / "ui/summary.json"), True)
                else:
                    result.update(support.run_tests(source, cache, destination, mutant.test, args.timeout_seconds))
                    status, reason = support.classify(result, (destination / "test.log").read_text(errors="replace"), mutant, {mutant.test})
                result.update(status=status, reason=reason)
            except Exception as error: result["reason"] = str(error)
            finally:
                for path, content in originals.items(): path.write_bytes(content)
            report["mutants"][mutant.name] = result; support.save_json(destination / "result.json", result); save()
            print(mutant.name + ": " + result["status"], flush=True)
        statuses = {r["status"] for r in report["mutants"].values()}
        report["status"] = "passed" if statuses == {"killed"} else "failed" if "survived" in statuses else "inconclusive"
        code = 0 if report["status"] == "passed" else 1 if report["status"] == "failed" else 2
    except BaseException as error:
        report.update(status="inconclusive", error=str(error)); code = 2
    finally:
        try:
            if source.exists(): support.git("worktree", "remove", "--force", str(source))
            shutil.rmtree(temporary); report["isolatedSnapshotRemoved"] = True
        except Exception as error: report.update(status="inconclusive", cleanupError=str(error)); code = 2
        save()
    print("EDITOR_SENSITIVITY_REPORT=" + str(output / "report.json"))
    return code


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupt)
    raise SystemExit(main())
