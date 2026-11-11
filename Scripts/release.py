#!/usr/bin/env python3
"""One resumable, change-aware release for iOS, Mac App Store and Homebrew."""
import argparse
import base64
import concurrent.futures
import copy
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

from release_app_store import AppStorePublisher, Pending, listing, version_state
from release_plan import AppInputs, next_version, plan, tree, version_tuple

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / ".build/releases"
STATE_ASSET = "release-state.json"
SIGNING = Path.home() / "Library/Application Support/NeoAnki2 Signing"
TAP = "neoanki2/homebrew-tap"


def run(args, cwd=None, log=None, env=None, check=True):
    cwd = ROOT if cwd is None else cwd
    if log:
        with Path(log).open("wb") as stream:
            result = subprocess.run(args, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        if check and result.returncode:
            raise RuntimeError(f"{args[0]} failed; see {log}")
        return result
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if check and result.returncode:
        # Never echo authentication commands or private key arguments.
        raise RuntimeError(result.stderr.strip() or args[0] + " failed")
    return result.stdout.strip() if check else result


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class GitHub:
    def __init__(self):
        run(["gh", "auth", "status"])
        self.repository = run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"])

    def api(self, path, method="GET", body=None):
        args = ["gh", "api", "repos/" + self.repository + "/" + path, "--method", method]
        if body is not None:
            # Structured JSON on stdin preserves newlines and avoids shell interpolation.
            result = subprocess.run(args + ["--input", "-"], input=json.dumps(body),
                                    capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stderr.strip())
            return json.loads(result.stdout) if result.stdout.strip() else None
        return json.loads(run(args))

    def history(self):
        releases = json.loads(run(["gh", "release", "list", "--repo", self.repository,
                                   "--limit", "1000", "--json", "tagName,isDraft"]))
        numbered = []
        for item in releases:
            try:
                version_tuple(item["tagName"])
            except ValueError:
                continue
            numbered.append(item)
        return sorted(numbered, key=lambda r: version_tuple(r["tagName"]), reverse=True)

    def baseline(self):
        baseline = json.loads((ROOT / ".release/baseline.json").read_text())
        history = self.history()
        if history:
            tag = history[0]["tagName"]
            info = json.loads(run(["gh", "release", "view", tag, "--repo", self.repository,
                                   "--json", "assets,targetCommitish,isDraft"]))
            if any(a["name"] == STATE_ASSET for a in info["assets"]):
                result = subprocess.run(["gh", "release", "download", tag, "--repo", self.repository,
                                         "--pattern", STATE_ASSET, "--output", "-"], capture_output=True)
                if result.returncode:
                    raise RuntimeError("Could not read the canonical release checkpoint")
                baseline = json.loads(result.stdout)
                if baseline.get("schema_version") != 1 or baseline.get("revision") != info["targetCommitish"]:
                    raise RuntimeError("Release checkpoint schema or source identity is invalid")
            elif version_tuple(tag) > version_tuple(baseline["version"]):
                raise RuntimeError("Latest release has no unified checkpoint; migrate .release/baseline.json first")
        return baseline, history

    def snapshot(self, version):
        # Every release gets a fresh branch; bot commits on a previous release
        # branch cannot cause a force-push or overwrite another person's work.
        branch = "release/" + version + "-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d%H%M%S")
        run(["git", "switch", "-c", branch])
        run(["git", "add", "-A"])
        if run(["git", "diff", "--cached", "--quiet"], check=False).returncode:
            run(["git", "commit", "-m", "Release NeoAnki2 " + version])
        run(["git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
             "fetch", "https://github.com/" + self.repository + ".git", "refs/heads/main"])
        base = run(["git", "rev-parse", "FETCH_HEAD"])
        if run(["git", "merge-base", "--is-ancestor", base, "HEAD"], check=False).returncode:
            run(["git", "merge", "--no-edit", base])
        revision = run(["git", "rev-parse", "HEAD"])
        run(["git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
             "push", "https://github.com/" + self.repository + ".git", "HEAD:refs/heads/" + branch])
        body = WORK / "pr-body.md"
        body.write_text("Publish affected distributions from exact source `" + revision + "`.\n\n"
                        "The unified release runs relevant headless checks, validates signed artifacts, "
                        "and records per-channel publication in the release checkpoint.\n")
        url = run(["gh", "pr", "create", "--repo", self.repository, "--base", "main", "--head", branch,
                   "--title", "Release NeoAnki2 " + version, "--body-file", str(body)])
        return revision, branch, url

    def reserve(self, state):
        tag = "v" + state["version"]
        # Creating a Git ref is atomic even before the draft is published.
        # Another machine cannot reserve this version for a different source.
        refs = [r for r in self.api("git/matching-refs/tags/" + tag) if r["ref"] == "refs/tags/" + tag]
        if refs and refs[0]["object"]["sha"] != state["revision"]:
            raise RuntimeError("Another source reserved " + tag)
        if not refs:
            self.api("git/refs", "POST", {"ref": "refs/tags/" + tag, "sha": state["revision"]})
        existing = run(["gh", "release", "view", tag, "--repo", self.repository,
                        "--json", "targetCommitish"], check=False)
        if existing.returncode:
            run(["gh", "release", "create", tag, "--repo", self.repository, "--draft", "--verify-tag",
                 "--target", state["revision"], "--title", "NeoAnki2 " + state["version"],
                 "--notes", state["notes"]])
        elif json.loads(existing.stdout)["targetCommitish"] != state["revision"]:
            raise RuntimeError("Reserved release source does not match the checkpoint")

    def checkpoint(self, path, state):
        public = {k: v for k, v in state.items() if k not in ("directory", "worktree")}
        asset = Path(path).parent / STATE_ASSET
        write_json(asset, public)
        run(["gh", "release", "upload", "v" + state["version"], str(asset),
             "--repo", self.repository, "--clobber"])

    def assets(self, version):
        return json.loads(run(["gh", "release", "view", "v" + version, "--repo", self.repository,
                               "--json", "assets"]))["assets"]

    def download(self, version, name, path):
        run(["gh", "release", "download", "v" + version, "--repo", self.repository,
             "--pattern", name, "--output", str(path), "--clobber"])


def make_api(config_path):
    adapter = module(ROOT / "Scripts/release-ios.py", "release_ios_api")
    config = json.loads(config_path.read_text())
    if config.get("team_id", adapter.TEAM) != adapter.TEAM:
        raise ValueError("Configured Apple signing team differs from this app")
    api = adapter.AppleAPI(config)
    return api, api.app()


def allocate(baseline, history, api, app_id, requested=None):
    versions = [baseline["version"], *(r["tagName"] for r in history)]
    versions.extend(v["attributes"]["versionString"]
                    for v in api.list("apps/" + app_id + "/appStoreVersions"))
    version = ".".join(map(str, version_tuple(requested))) if requested else next_version(versions)
    if version_tuple(version) <= max(map(version_tuple, versions)):
        raise ValueError("Release version must be greater than every reserved and Store version")
    builds = [int(b["attributes"]["version"]) for b in api.list("builds", **{"filter[app]": app_id})
              if b["attributes"]["version"].isdigit()]
    builds += [int(c.get("build", "0")) for c in baseline["channels"].values()]
    builds.append(int(baseline.get("build", "0")))
    return version, str(max(builds, default=0) + 1)


def preflight(channels, signing):
    if "homebrew" in channels:
        environment = dict(os.environ, NEOANKI_SIGNING_DIR=str(signing.resolve()))
        run(["python3", str(ROOT / "Scripts/sign-macos-app.py"), "--check"], env=environment)
    required = ["Apple-Distribution.cert.pem", "Apple-Distribution.key.pem"]
    if "mac" in channels:
        required += ["Mac-Installer-Distribution.cert.pem", "Mac-Installer-Distribution.key.pem"]
    for name in required:
        if not (signing / name).is_file():
            raise ValueError("Missing saved signing input: " + name)


class Release:
    def __init__(self, github, api, app_id, state, directory, config, signing):
        self.github, self.api, self.app_id = github, api, app_id
        self.state, self.directory = state, Path(directory)
        self.config, self.signing = config, signing
        self.path = self.directory / "release.json"
        self.lock = threading.RLock()
        self.source = self.directory / "source"
        if not self.source.exists():
            run(["git", "worktree", "add", "--detach", str(self.source), state["revision"]])
        if run(["git", "rev-parse", "HEAD"], cwd=self.source) != state["revision"]:
            raise RuntimeError("Release worktree source changed")
        self.verify_source()
        self.state["directory"], self.state["worktree"] = str(self.directory), str(self.source)

    def verify_source(self):
        if tree(self.source) != tree(self.source, self.state["revision"]):
            raise RuntimeError("Pinned release worktree contains source changes")

    def save(self, remote=False):
        with self.lock:
            write_json(self.path, self.state)
            if remote:
                self.github.checkpoint(self.path, self.state)

    def validate(self):
        if self.state.get("validation_failure"):
            raise RuntimeError("This candidate failed verification; fix the cause and abandon it before releasing new source")
        if "validation" in self.state:
            for item in self.state["validation"]:
                if sha(self.directory / item["log"]) != item["sha256"]:
                    raise RuntimeError("Validation evidence changed")
            return
        commands = []
        for prefix, names in self.state["tests"].items():
            cmd = ["swift", "test", "--parallel", "--filter", "|".join(names)]
            if not prefix:
                cmd += ["--skip", "AppLaunchSmokeTests"]
            commands.append((prefix, cmd))
        if any(p.startswith("Sources/NeoAnkiAPI/") for p in self.state["changed_paths"]):
            commands.append(("", ["swift", "run", "neoanki-api-reference", "check"]))
        environment = os.environ.copy()
        environment["SDKROOT"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
        evidence = self.state.get("validation_progress", [])
        for index, (prefix, command) in enumerate(commands):
            log = self.directory / f"verify-{index}.log"
            if index < len(evidence):
                if sha(log) != evidence[index]["sha256"]:
                    raise RuntimeError("Validation evidence changed")
                continue
            print("Verifying " + " ".join(command), flush=True)
            try:
                run(command, cwd=self.source / prefix, log=log, env=environment)
            except Exception:
                self.state["validation_failure"] = {"command": command, "log": log.name,
                    "sha256": sha(log) if log.exists() else None}
                self.save(remote=True)
                raise
            evidence.append({"command": command, "package": prefix, "log": log.name, "sha256": sha(log)})
            self.state["validation_progress"] = evidence
            self.save()
        self.state["validation"] = evidence
        self.save()

    def builder(self, channel):
        filename = "release-ios.py" if channel == "ios" else "release-macos-app-store.py"
        adapter = module(self.source / "Scripts" / filename, "release_builder_" + channel)
        owner = self

        class Builder(adapter.Workflow):
            def prepare(self):
                # The controller already ran the dependency-selected checks once.
                self.archive()

            def save(self):
                super().save()
                upload = self.state.get("phases", {}).get("upload")
                if upload and upload.get("status") == "attempting":
                    with owner.lock:
                        receipt = owner.state["phases"][channel]
                        if receipt.get("status") != "uploading":
                            receipt.update(status="uploading", package_sha256=next(
                                value for key, value in upload.items() if key.endswith("_sha256")))
                            # Durable cross-machine marker before sending to Apple.
                            owner.save(remote=True)

        args = SimpleNamespace(stage="upload", output=self.directory / channel,
            version=self.state["version"], build=self.state["build"], config=self.config,
            signing_dir=self.signing, reuse_build_from=None, allow_physical_test_waivers=False,
            rejection_evidence=self.source / ".build/rejection.json")
        return Builder(args)

    def build(self, channel):
        receipt = self.state["phases"][channel]
        if receipt.get("status") in ("uploading", "uploaded", "submitted", "available", "published"):
            return
        if channel == "homebrew":
            folder = self.directory / "homebrew"
            dmg = folder / ("NeoAnki2-" + self.state["version"] + "-mac-universal.dmg")
            if receipt.get("artifact_sha256") and dmg.exists() and sha(dmg) == receipt["artifact_sha256"]:
                return
            if receipt.get("artifact_sha256"):
                names = {a["name"] for a in self.github.assets(self.state["version"])}
                if dmg.name in names:
                    folder.mkdir(parents=True, exist_ok=True)
                    required = [dmg.name, dmg.name + ".sha256", "notarization.json"]
                    if not set(required) <= names:
                        raise RuntimeError("Partial Homebrew assets require the original signing Mac's receipt")
                    for name in required:
                        self.github.download(self.state["version"], name, folder / name)
                    if sha(dmg) != receipt["artifact_sha256"]:
                        raise RuntimeError("Published DMG differs from the reserved artifact")
                    return
            environment = os.environ.copy()
            environment.update(NEOANKI_RELEASE_VERSION=self.state["version"],
                               NEOANKI_RELEASE_BUILD_NUMBER=self.state["build"],
                               NEOANKI_SIGNING_DIR=str(self.signing))
            # Developer ID signing and App Store exports both touch the user's
            # Keychain search list. Serialize those short-lived signing contexts.
            with (WORK / "signing.lock").open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                run([str(self.source / "Scripts/build-release-artifact.sh"), str(folder)],
                    cwd=self.source, log=self.directory / "homebrew-build.log", env=environment)
            expected = dmg.with_suffix(dmg.suffix + ".sha256").read_text().split()[0]
            if sha(dmg) != expected:
                raise RuntimeError("Homebrew artifact checksum mismatch")
            receipt.update(status="built", artifact_sha256=expected, artifact=dmg.name)
        else:
            self.builder(channel).archive()
            receipt["status"] = "built"
        self.save()

    def export(self, channel):
        receipt = self.state["phases"][channel]
        if channel == "homebrew" or receipt.get("status") in ("uploading", "uploaded", "submitted", "available"):
            return
        with (WORK / "signing.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.builder(channel).export()

    def publish_store(self, channel):
        receipt = self.state["phases"][channel]
        if receipt.get("status") not in ("uploading", "uploaded", "submitted", "available"):
            builder = self.builder(channel)
            builder.upload()
            receipt["status"] = "uploaded"
            self.save(remote=True)
        if receipt.get("status") not in ("submitted", "available"):
            publisher = AppStorePublisher(self.api, self.app_id, "IOS" if channel == "ios" else "MAC_OS",
                self.state["version"], self.state["build"], receipt, lambda: self.save(remote=True),
                listing(self.source, "IOS" if channel == "ios" else "MAC_OS"), self.state["notes"])
            publisher.submit()
        with self.lock:
            self.state["channels"][channel] = {
                "version": self.state["version"], "build": self.state["build"],
                "revision": self.state["revision"], "inputs": self.state["inputs"][channel],
                "build_id": receipt["build_id"], "status": receipt["status"],
            }
            self.save(remote=True)

    def publish_homebrew(self):
        receipt = self.state["phases"]["homebrew"]
        if receipt.get("status") == "published":
            return
        tag = "v" + self.state["version"]
        dmg = self.directory / "homebrew" / receipt["artifact"]
        if sha(dmg) != receipt["artifact_sha256"]:
            raise RuntimeError("Homebrew artifact changed after validation")
        cask = ('cask "neoanki2" do\n  version "' + self.state["version"] + '"\n  sha256 "' +
                receipt["artifact_sha256"] + '"\n\n  url "https://github.com/' + self.github.repository +
                '/releases/download/v#{version}/NeoAnki2-#{version}-mac-universal.dmg"\n'
                '  name "NeoAnki2"\n  desc "Native, local-first spaced-repetition app with FSRS scheduling"\n'
                '  homepage "https://neoanki2.github.io/"\n  depends_on macos: :sonoma\n'
                '  app "NeoAnki2.app"\nend\n')
        prior = json.loads(run(["gh", "api", "repos/" + TAP + "/contents/Casks/neoanki2.rb?ref=main"]))
        prior_content = base64.b64decode(prior["content"]).decode()
        import re
        current_version = re.search(r'\bversion\s+"([^"]+)"', prior_content)
        if not current_version or version_tuple(current_version[1]) > version_tuple(self.state["version"]):
            raise RuntimeError("Official tap is newer or has an unknown version; refusing to downgrade")
        # Only the progress checkpoint is mutable. Existing signed artifacts
        # must retain their original bytes, including on a partial-publication resume.
        assets = {a["name"] for a in self.github.assets(self.state["version"])}
        files = [dmg, Path(str(dmg) + ".sha256"), dmg.parent / "notarization.json"]
        missing = []
        for artifact in files:
            if artifact.name in assets:
                observed = self.directory / ("published-" + artifact.name)
                self.github.download(self.state["version"], artifact.name, observed)
                if sha(observed) != sha(artifact):
                    raise RuntimeError("Published asset bytes changed: " + artifact.name)
            else:
                missing.append(str(artifact))
        if missing:
            run(["gh", "release", "upload", tag, *missing, "--repo", self.github.repository])
        run(["gh", "release", "edit", tag, "--repo", self.github.repository, "--draft=false", "--latest"])
        if prior_content != cask:
            payload = self.directory / "tap-update.json"
            write_json(payload, {"message": "Update NeoAnki2 to " + self.state["version"],
                                "branch": "main", "sha": prior["sha"],
                                "content": base64.b64encode(cask.encode()).decode()})
            run(["gh", "api", "--method", "PUT", "repos/" + TAP + "/contents/Casks/neoanki2.rb",
                 "--input", str(payload)])
        with self.lock:
            receipt["status"] = "published"
            self.state["channels"]["homebrew"] = {
                "version": self.state["version"], "build": self.state["build"],
                "revision": self.state["revision"], "inputs": self.state["inputs"]["mac"], "status": "published",
            }
            self.save(remote=True)

    def publish(self):
        self.verify_source()
        history = self.github.history()
        if history and version_tuple(history[0]["tagName"]) > version_tuple(self.state["version"]):
            raise RuntimeError("A newer release was reserved; refusing to publish an older candidate")
        errors, pending = {}, {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures = {pool.submit(self.publish_homebrew if c == "homebrew" else self.publish_store,
                                   *([] if c == "homebrew" else [c])): c for c in self.state["selected"]}
            for future in concurrent.futures.as_completed(futures):
                channel = futures[future]
                try:
                    future.result()
                except Pending as error:
                    pending[channel] = str(error)
                except Exception as error:
                    errors[channel] = str(error)
        self.state["pending"], self.state["errors"] = pending, errors
        self.state["complete"] = not pending and not errors
        self.save(remote=True)
        if self.state["complete"]:
            # iOS-only releases must not displace the latest Mac DMG download.
            run(["gh", "release", "edit", "v" + self.state["version"], "--repo", self.github.repository,
                 "--draft=false", "--latest=" + ("true" if "homebrew" in self.state["selected"] else "false")])
        return errors, pending

    def publish_until_ready(self, wait_seconds):
        deadline = time.monotonic() + wait_seconds
        errors, waiting = self.publish()
        if waiting and not errors:
            print("Waiting for Apple processing/cancellation; completed channels are retained.", flush=True)
        while waiting and not errors and time.monotonic() < deadline:
            time.sleep(min(5, max(0, deadline - time.monotonic())))
            errors, waiting = self.publish()
        return errors, waiting


def status(state, api, app_id):
    result = {"version": state["version"], "revision": state.get("revision"), "channels": {}}
    for channel, released in state["channels"].items():
        receipt = state.get("phases", {}).get(channel, {})
        version = state["version"] if channel in state.get("selected", []) else released["version"]
        if channel == "homebrew":
            tap = json.loads(run(["gh", "api", "repos/" + TAP + "/contents/Casks/neoanki2.rb?ref=main"]))
            import re
            actual = re.search(r'\bversion\s+"([^"]+)"', base64.b64decode(tap["content"]).decode())
            result["channels"][channel] = {"version": actual[1] if actual else None,
                                           "state": receipt.get("status", released.get("status", "published"))}
        else:
            platform = "IOS" if channel == "ios" else "MAC_OS"
            versions = api.list("apps/" + app_id + "/appStoreVersions", **{
                "filter[platform]": platform, "filter[versionString]": version,
            })
            result["channels"][channel] = {"version": version,
                "state": [version_state(v) for v in versions] or ["NOT_YET_VISIBLE"]}
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--plan", action="store_true", help="read-only affected-channel/version preview")
    parser.add_argument("--offline", action="store_true", help="use migration baseline for an offline --plan")
    mode.add_argument("--resume", metavar="VERSION", help="resume the exact saved release, not a new version")
    mode.add_argument("--abandon", metavar="VERSION", help="stop a saved release without deleting its history or published channels")
    mode.add_argument("--status", action="store_true", help="read-only latest release/Apple state")
    parser.add_argument("--version", help="optional explicit shared version, greater than all existing versions")
    parser.add_argument("--notes", default="Bug fixes and reliability improvements.", help="App Store What's New and release notes")
    parser.add_argument("--wait-seconds", type=int, default=600,
                        help="bounded Apple processing/cancellation wait (default 600; 0 returns a checkpoint immediately)")
    parser.add_argument("--config", type=Path, default=SIGNING / "app-store-connect.json")
    parser.add_argument("--signing-dir", type=Path, default=SIGNING)
    args = parser.parse_args(argv)
    args.config = args.config.expanduser().resolve()
    args.signing_dir = args.signing_dir.expanduser().resolve()
    if args.wait_seconds < 0:
        parser.error("--wait-seconds must be nonnegative")
    for name in ("resume", "abandon"):
        if getattr(args, name):
            setattr(args, name, ".".join(map(str, version_tuple(getattr(args, name)))))
    if args.offline and not args.plan:
        parser.error("--offline is only available with --plan")
    WORK.mkdir(parents=True, exist_ok=True)
    with (WORK / "release.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        github = None if args.offline else GitHub()
        baseline, history = (json.loads((ROOT / ".release/baseline.json").read_text()), []) if args.offline else github.baseline()
        if args.status:
            api, app_id = make_api(args.config)
            print(json.dumps(status(baseline, api, app_id), indent=2))
            return 0
        if args.abandon:
            path = WORK / args.abandon / "release.json"
            state = json.loads(path.read_text()) if path.exists() else copy.deepcopy(baseline)
            if state["version"] != args.abandon or "selected" not in state:
                raise ValueError("No checkpoint exists for that version")
            if not state.get("reserved"):
                github.reserve(state)
                state["reserved"] = True
            state.update(complete=True, abandoned=True)
            write_json(path, state)
            github.checkpoint(path, state)
            print("Stopped release " + args.abandon + "; published channels and evidence retained.")
            return 0
        # Explicit recovery uses the pinned worktree even if today's manifest
        # is temporarily invalid or the developer is working on another change.
        proposal = None if args.resume else plan(ROOT, baseline, AppInputs.load(ROOT))
        active_path = WORK / "active.json"
        local = None
        if active_path.exists():
            pointer = json.loads(active_path.read_text())
            path = WORK / pointer["version"] / "release.json"
            if path.exists():
                candidate = json.loads(path.read_text())
                if not candidate.get("complete"):
                    local = candidate
        pending_state = local or (baseline if baseline.get("complete") is False else None)
        if local and version_tuple(local["version"]) < version_tuple(baseline["version"]):
            raise ValueError("Remote release advanced beyond the pending local release; inspect its checkpoint")
        if args.plan:
            if pending_state:
                print(json.dumps({"resume": pending_state["version"], "channels": pending_state["selected"],
                                  "phases": pending_state["phases"]}, indent=2))
                return 0
            if not args.offline and proposal["channels"]:
                api, app_id = make_api(args.config)
                proposal["version"], proposal["build"] = allocate(baseline, history, api, app_id, args.version)
            print(json.dumps({k: v for k, v in proposal.items() if k != "inputs"}, indent=2))
            return 0
        if not args.status and not args.resume and not proposal["channels"] and not pending_state:
            print("No application changes; nothing to release.")
            return 0
        api, app_id = make_api(args.config)
        resume = args.resume or (pending_state["version"] if pending_state else None)
        if resume:
            version_tuple(resume)
            path = WORK / resume / "release.json"
            state = json.loads(path.read_text()) if path.exists() else copy.deepcopy(baseline)
            if state["version"] != resume or "selected" not in state:
                raise ValueError("No checkpoint exists for requested release")
            if version_tuple(state["version"]) < version_tuple(baseline["version"]):
                raise ValueError("A newer release exists; refusing to resume an older version")
            if state.get("app_id", app_id) != app_id:
                raise ValueError("Saved release belongs to a different Apple app")
            if not args.resume and any(proposal["inputs"][p] != state["inputs"][p] for p in ("ios", "mac")):
                raise ValueError("App sources changed during a pending release; finish it with --resume " + resume)
        else:
            version, build = allocate(baseline, history, api, app_id, args.version)
            checked_channels = set(proposal["channels"])
            preflight(proposal["channels"], args.signing_dir)
            revision, branch, url = github.snapshot(version)
            if tree(ROOT) != tree(ROOT, revision):
                raise ValueError("Working tree changed during snapshot; release not reserved")
            # Integration may introduce additional app changes/dependencies.
            proposal = plan(ROOT, baseline, AppInputs.load(ROOT))
            if set(proposal["channels"]) - checked_channels:
                preflight(proposal["channels"], args.signing_dir)
            state = dict(schema_version=1, version=version, build=build, revision=revision,
                         repository=github.repository, branch=branch, pull_request=url, notes=args.notes,
                         selected=proposal["channels"], inputs=proposal["inputs"], tests=proposal["tests"],
                         changed_paths=proposal["changed_paths"], channels=copy.deepcopy(baseline["channels"]),
                         app_id=app_id, phases={c: {"status": "planned"} for c in proposal["channels"]}, complete=False)
            write_json(WORK / version / "release.json", state)
        write_json(active_path, {"version": state["version"]})
        if not state.get("reserved"):
            github.reserve(state)
            state["reserved"] = True
            write_json(WORK / state["version"] / "release.json", state)
            github.checkpoint(WORK / state["version"] / "release.json", state)
        release = Release(github, api, app_id, state, WORK / state["version"], args.config.resolve(), args.signing_dir.resolve())
        print("Release " + state["version"] + ": " + ", ".join(state["selected"]), flush=True)
        release.validate()
        # Build unsigned Store archives and the notarized DMG concurrently;
        # serialize Keychain exports, then publish independent channels together.
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            list(pool.map(release.build, state["selected"]))
        for channel in state["selected"]:
            release.export(channel)
        release.save(remote=True)
        errors, waiting = release.publish_until_ready(args.wait_seconds)
        # Hosted checks may gate the merge; publication never silently bypasses it.
        run(["gh", "pr", "merge", state["pull_request"], "--repo", github.repository,
             "--auto", "--merge"], check=False)
        print(json.dumps(status(state, api, app_id), indent=2))
        print("RELEASE_RECEIPT=" + str(release.path))
        for channel, message in {**waiting, **errors}.items():
            print(channel + ": " + message)
        if waiting:
            print("Resume with ./Scripts/release.sh --resume " + state["version"])
        return 1 if errors else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("RELEASE_ERROR=" + str(error), file=sys.stderr)
        sys.exit(1)
