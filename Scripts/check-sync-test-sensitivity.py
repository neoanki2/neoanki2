#!/usr/bin/env python3
"""Prove sync contracts detect selected regressions in an isolated source snapshot.

No mutant ever edits the user's checkout. A passing baseline is mandatory; only
an executed target test failing with its contract marker kills a mutant. Build,
process, timeout, and mutation-anchor errors are inconclusive campaign failures.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import tarfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SUITE = "SyncConvergenceContractTests"
SERVICE = "Sources/NeoAnkiCloudSync/OfflineFirstSyncService.swift"
METADATA = "Sources/NeoAnkiCloudSync/SyncMetadataStore.swift"
ADAPTER = "Sources/NeoAnkiCloudSync/SQLiteLibrarySyncAdapter.swift"
DATABASE = "NeoAnkiCore/Sources/NeoAnkiCore/Database/SQLiteDatabase.swift"


@dataclasses.dataclass(frozen=True)
class Edit:
    path: str
    before: str
    after: str


@dataclasses.dataclass(frozen=True)
class Mutant:
    name: str
    description: str
    test: str
    markers: tuple[str, ...]
    edits: tuple[Edit, ...]

    @property
    def marker(self) -> str:
        return self.markers[0]


MUTANTS = (
    Mutant("absolute-queued-paths", "Restore installation-specific absolute queued asset URLs.",
           "relocatedMixedBatchPreservesReviewsAndMedia", ("SYNC_CONTRACT_DATA", "SYNC_CONTRACT_ASSET_RELOCATION", "SYNC_CONTRACT_VISIBLE"), (
               Edit(METADATA,
                    "        metadata.stagedInbound = metadata.stagedInbound.map(resolveAssetLocation)\n"
                    "        metadata.pendingOutbound = metadata.pendingOutbound?.map(resolveAssetLocation)\n",
                    "        // Mutant: leave queued asset URLs tied to the old container.\n"),
               Edit(METADATA,
                    "        stored.stagedInbound = stored.stagedInbound.map(relativeAssetLocation)\n"
                    "        stored.pendingOutbound = stored.pendingOutbound?.map(relativeAssetLocation)\n",
                    "        // Mutant: persist absolute queued asset URLs.\n"))),
    Mutant("nested-type-deletion", "Reintroduce a nested transaction inside a synchronized type deletion.",
           "relocatedMixedBatchPreservesReviewsAndMedia", ("SYNC_CONTRACT_DATA", "SYNC_CONTRACT_ASSET_RELOCATION"), (
               Edit(DATABASE, "try deleteItemTypeWithoutTransaction(id: uuid)",
                    "try deleteItemType(id: uuid)"),)),
    Mutant("dropped-review-apply", "Acknowledge an inbound review without applying its immutable history.",
           "relocatedMixedBatchPreservesReviewsAndMedia", ("SYNC_CONTRACT_DATA", "SYNC_CONTRACT_VISIBLE"), (
               Edit(ADAPTER, "case let .review(value): mutations.append(.review(value))",
                    "case .review: break // Mutant: silently discard the review."),)),
    Mutant("disabled-local-scheduling", "Do not schedule automatic sync after a committed local edit.",
           "automaticReviewUpdatesVisibleSummaryWithoutRecoveryPoll", ("SYNC_CONTRACT_AUTOMATIC_SEND",), (
               Edit(SERVICE, "await self?.scheduleLocalSync(after: cursor)",
                    "if cursor == Int64.min { await self?.scheduleLocalSync(after: cursor) }"),)),
    Mutant("missing-library-publication", "Commit remote data without notifying visible library models.",
           "automaticReviewUpdatesVisibleSummaryWithoutRecoveryPoll", ("SYNC_CONTRACT_VISIBLE",), (
               Edit(SERVICE, "if !recovered.isEmpty { await libraryChangeEvents.publish() }",
                    "// Mutant: omit committed inbound library-change publication."),)),
    Mutant("debounce-sixty-seconds", "Delay automatic local uploads for sixty seconds.",
           "automaticReviewUpdatesVisibleSummaryWithoutRecoveryPoll", ("SYNC_CONTRACT_DEBOUNCE",), (
               Edit(SERVICE, ".milliseconds(600)", ".seconds(60)"),)),
)
BY_NAME = {mutant.name: mutant for mutant in MUTANTS}


def timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def git(*arguments: str, cwd: Path | None = None, data: bytes | None = None) -> bytes:
    result = subprocess.run(["git", "-C", str(cwd or ROOT), *arguments], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise RuntimeError("git " + " ".join(arguments[:3]) + ": "
                           + result.stderr.decode(errors="replace").strip())
    return result.stdout


def relevant_untracked(path: str) -> bool:
    # Include new task source/fixtures while excluding unrelated root scratch
    # files. Ignored build trees are already excluded by git ls-files.
    return path.split("/", 1)[0] in {
        "Sources", "Tests", "NeoAnkiCore", "Scripts", "Config", "Platforms",
        "Packaging", "Xcode", "Extensions", "Tools",
    }


def snapshot(source: Path, output: Path) -> dict:
    head = git("rev-parse", "HEAD").decode().strip()
    patch = git("diff", "--binary", "HEAD", "--", ".")
    (output / "working-tree.patch").write_bytes(patch)
    git("worktree", "add", "--detach", str(source), head)
    if patch:
        git("apply", "--binary", "--whitespace=nowarn", cwd=source, data=patch)
    copied = []
    untracked = git("ls-files", "--others", "--exclude-standard", "-z")
    for raw in untracked.split(b"\0"):
        if not raw:
            continue
        name = os.fsdecode(raw)
        if not relevant_untracked(name):
            continue
        original, destination = ROOT / name, source / name
        if original.is_symlink():
            raise RuntimeError("Untracked symlink is not safe snapshot input: " + name)
        if not original.is_file():
            raise RuntimeError("Untracked snapshot input is not a regular file: " + name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, destination)
        copied.append({"path": name, "sha256": sha(destination.read_bytes())})
    if git("rev-parse", "HEAD").decode().strip() != head or git("diff", "--binary", "HEAD", "--", ".") != patch:
        raise RuntimeError("Tracked checkout changed while capturing the source snapshot; no campaign was run.")
    current_untracked = {os.fsdecode(raw) for raw in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
                         if raw and relevant_untracked(os.fsdecode(raw))}
    if current_untracked != {item["path"] for item in copied}:
        raise RuntimeError("Untracked source list changed while capturing the snapshot; no campaign was run.")
    for item in copied:
        if sha((ROOT / item["path"]).read_bytes()) != item["sha256"]:
            raise RuntimeError("Untracked source changed while capturing the snapshot: " + item["path"])
    with tarfile.open(output / "untracked-source.tar.gz", "w:gz") as archive:
        for item in copied:
            archive.add(source / item["path"], arcname=item["path"], recursive=False)
    result = {"head": head, "workingTreePatchSHA256": sha(patch), "untrackedFiles": copied,
              "untrackedSourceArchiveSHA256": sha((output / "untracked-source.tar.gz").read_bytes()),
              "note": "HEAD plus staged/unstaged tracked changes and untracked source/fixtures; no ignored build inputs."}
    save_json(output / "snapshot.json", result)
    return result


def contract_environment(artifacts: Path) -> tuple[dict[str, str], dict[str, str]]:
    environment = dict(os.environ)
    # Qualification uses its own deterministic cost/coverage, never a caller's
    # replay, stress seed, or evidence path from an unrelated CI invocation.
    for key in list(environment):
        if key.startswith("NEOANKI_SYNC_CONTRACT_"):
            del environment[key]
    settings = {"NEOANKI_SYNC_CONTRACT_ARTIFACTS": str(artifacts.resolve()),
                "NEOANKI_SYNC_CONTRACT_SEEDS": "2", "NEOANKI_SYNC_CONTRACT_STEPS": "12",
                "NEOANKI_SYNC_CONTRACT_SEED_BASE": "0"}
    environment.update(settings)
    return environment, settings


def run_tests(source: Path, cache: Path, output: Path, filter_: str, timeout: int) -> dict:
    command = ["swift", "test", "--scratch-path", str(cache), "--filter", filter_]
    started = time.monotonic()
    environment, settings = contract_environment(output / "contract-artifacts")
    result = {"command": command, "filter": filter_, "environment": settings, "startedAt": timestamp(), "timedOut": False}
    with (output / "test.log").open("wb") as log:
        try:
            process = subprocess.Popen(command, cwd=source, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True, env=environment)
        except OSError as error:
            result.update(exitCode=None, launchError=str(error))
        else:
            try:
                result["exitCode"] = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                result["timedOut"] = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                result["exitCode"] = process.returncode
            except BaseException:
                # Never leave a compiler/test process writing a tree being removed.
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
    result["elapsedSeconds"] = round(time.monotonic() - started, 3)
    result["logSHA256"] = sha((output / "test.log").read_bytes())
    return result


def test_started(log: str, name: str) -> bool:
    return re.search(r"\bTest\s+" + re.escape(name) + r"\([^\n]*\) started\.", log) is not None


def matching_issue(log: str, mutant: Mutant) -> bool:
    # Markers must be in the actual target test's issue diagnostics, not merely
    # printed at startup or present in a compiler's source excerpt.
    starts = list(re.finditer(r"(?m)^.*Test\s+" + re.escape(mutant.test)
                              + r"\([^\n]*\) recorded an issue[^\n]*(?:\n|$)", log))
    for match in starts:
        remaining = log[match.end():]
        boundary = re.search(r"(?m)^[◇✔✘].*(?:Test|Suite)\b", remaining)
        end = match.end() + (boundary.start() if boundary else len(remaining))
        if any(marker in log[match.start():end] for marker in mutant.markers):
            return True
    return False


def classify(result: dict, log: str, mutant: Mutant | None,
             required_tests: set[str]) -> tuple[str, str]:
    if result.get("launchError"):
        return "inconclusive", "Unable to launch the Swift test command: " + result["launchError"]
    if result["timedOut"]:
        return "inconclusive", "Process timeout is not a killed mutant."
    if result.get("exitCode", 0) is not None and result.get("exitCode", 0) < 0:
        return "inconclusive", "The test command terminated by a signal."
    if re.search(r"unexpected signal|segmentation fault|program crashed|error: fatalError", log, re.IGNORECASE):
        return "inconclusive", "A process/compiler failure is not a killed mutant."
    if "Build complete!" not in log:
        return "inconclusive", "Swift build did not complete successfully."
    if not all(test_started(log, name) for name in required_tests):
        return "inconclusive", "The required contract test did not execute."
    if mutant is None:
        if result["exitCode"] == 0 and re.search(r"Test run with [1-9][0-9]* tests?", log):
            return "passed", "Unmodified snapshot passed the contract baseline."
        return "failed", "The baseline failed; no mutant result can be credited."
    if result["exitCode"] == 0:
        return "survived", "The mutated implementation passed its contract test."
    failed = re.search(r"\bTest\s+" + re.escape(mutant.test)
                       + r"\([^\n]*\).*failed after", log)
    if failed and matching_issue(log, mutant):
        return "killed", "The executed contract failed with the expected assertion marker."
    return "inconclusive", "Failure did not contain the targeted contract assertion marker."


def apply_mutant(source: Path, mutant: Mutant, output: Path) -> dict[Path, bytes]:
    originals: dict[Path, bytes] = {}
    try:
        for edit in mutant.edits:
            path = source / edit.path
            try:
                path.resolve().relative_to(source.resolve())
            except ValueError:
                raise RuntimeError("Mutation target escapes the isolated snapshot: " + edit.path)
            if path.is_symlink():
                raise RuntimeError("Mutation target must be a regular snapshot file: " + edit.path)
            originals.setdefault(path, path.read_bytes())
            text = path.read_text()
            if text.count(edit.before) != 1:
                raise RuntimeError(f"{mutant.name}: expected exactly one mutation anchor in {edit.path}; "
                                   f"found {text.count(edit.before)}. Update the qualifier for the new source layout.")
            path.write_text(text.replace(edit.before, edit.after, 1))
        diff = "".join("".join(difflib.unified_diff(
            original.decode().splitlines(keepends=True), path.read_text().splitlines(keepends=True),
            fromfile="a/" + str(path.relative_to(source)), tofile="b/" + str(path.relative_to(source))))
            for path, original in originals.items())
        (output / "mutant.diff").write_text(diff)
        return originals
    except BaseException:
        for path, original in originals.items():
            path.write_bytes(original)
        raise


def write_report(output: Path, report: dict) -> None:
    save_json(output / "report.json", report)
    lines = ["# Sync contract mutation qualification", "",
             "Status: **" + report["status"] + "**", "",
             "| Run | Result | Seconds | Reason |", "| --- | --- | ---: | --- |"]
    for name, result in [("baseline", report.get("baseline"))] + list(report.get("mutants", {}).items()):
        if result:
            lines.append(f"| {name} | {result['status']} | {result.get('elapsedSeconds', '')} | "
                         + result.get("reason", "").replace("|", "\\|") + " |")
    if report.get("error"):
        lines += ["", "Error: " + report["error"]]
    if report.get("cleanupError"):
        lines += ["", "Cleanup error: " + report["cleanupError"]]
    lines += ["", "Source patch, snapshot hashes, mutation diffs, original test logs, and individual results are retained.",
              "A killed mutant proves this specific regression was detected; it is not a zero-bug or live CloudKit guarantee.", ""]
    (output / "report.md").write_text("\n".join(lines))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="list mutants without creating a snapshot or running tests")
    parser.add_argument("--mutant", action="append", choices=BY_NAME,
                        help="qualify only this mutant (repeatable; default: all)")
    parser.add_argument("--output", type=Path, help="new or empty evidence directory (default: .build/sync-sensitivity/TIMESTAMP-ID)")
    parser.add_argument("--timeout-seconds", type=int, default=900,
                        help="maximum wall time for each build/test invocation (default: 900)")
    args = parser.parse_args(argv)
    selected = [mutant for mutant in MUTANTS if not args.mutant or mutant.name in args.mutant]
    if args.list:
        for mutant in selected:
            print(mutant.name + "\t" + mutant.description + "\t" + SUITE + "/" + mutant.test)
        return 0
    if args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    output = (args.output or ROOT / ".build/sync-sensitivity" /
              (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])).resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("--output must be a new or empty directory; existing evidence is never overwritten")
    if output == ROOT or ROOT / ".git" in [output, *output.parents]:
        parser.error("--output must not be the checkout root or its Git metadata")
    try:
        relative_output = output.relative_to(ROOT)
    except ValueError:
        pass
    else:
        if not relative_output.parts or relative_output.parts[0] != ".build":
            parser.error("Evidence inside the checkout must be under .build; use an external directory otherwise")
    output.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix="neoanki-sync-sensitivity-"))
    source, cache = temporary / "source", temporary / "swift-build"
    report = {"schemaVersion": 1, "startedAt": timestamp(), "status": "running", "mutants": {},
              "selected": [mutant.name for mutant in selected], "sourceSnapshot": str(source),
              "isolatedBuildCache": str(cache), "output": str(output)}
    write_report(output, report)
    code = 2
    try:
        report["snapshot"] = snapshot(source, output)
        baseline_dir = output / "baseline"
        baseline_dir.mkdir()
        baseline = run_tests(source, cache, baseline_dir, SUITE, args.timeout_seconds)
        status, reason = classify(baseline, (baseline_dir / "test.log").read_text(errors="replace"),
                                  None, {mutant.test for mutant in selected})
        baseline.update(status=status, reason=reason)
        report["baseline"] = baseline
        save_json(baseline_dir / "result.json", baseline)
        write_report(output, report)
        print("baseline: " + status, flush=True)
        if status != "passed":
            raise RuntimeError(reason)
        for mutant in selected:
            destination = output / mutant.name
            destination.mkdir()
            result = {"status": "inconclusive", "description": mutant.description,
                      "test": mutant.test, "expectedMarkers": list(mutant.markers)}
            originals: dict[Path, bytes] = {}
            try:
                originals = apply_mutant(source, mutant, destination)
                result.update(run_tests(source, cache, destination, SUITE + "/" + mutant.test,
                                        args.timeout_seconds))
                status, reason = classify(result, (destination / "test.log").read_text(errors="replace"),
                                          mutant, {mutant.test})
                result.update(status=status, reason=reason)
            except Exception as error:
                result["reason"] = str(error)
            finally:
                for path, original in originals.items():
                    path.write_bytes(original)
            report["mutants"][mutant.name] = result
            save_json(destination / "result.json", result)
            write_report(output, report)
            print(mutant.name + ": " + result["status"], flush=True)
        outcomes = {result["status"] for result in report["mutants"].values()}
        if "inconclusive" in outcomes:
            code, report["status"] = 2, "inconclusive"
        elif outcomes == {"killed"}:
            code, report["status"] = 0, "passed"
        else:
            code, report["status"] = 1, "failed"
    except KeyboardInterrupt:
        code = 130
        report.update(status="inconclusive", error="Campaign interrupted; no incomplete run is credited.")
    except Exception as error:
        report.update(status="inconclusive", error=str(error))
    finally:
        try:
            if source.exists():
                git("worktree", "remove", "--force", str(source))
            shutil.rmtree(temporary)
            report["isolatedTreeAndBuildCacheRemoved"] = True
        except Exception as error:
            report.update(cleanupError=str(error), isolatedTreeAndBuildCacheRemoved=False, status="inconclusive")
            code = 2
        report["completedAt"] = timestamp()
        write_report(output, report)
    print("SYNC_SENSITIVITY_REPORT=" + str(output / "report.json"), flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
