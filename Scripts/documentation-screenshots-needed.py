#!/usr/bin/env python3
"""Report whether documentation screenshots must be captured for a revision."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CAPTURE_INPUT_FILES = {
    ".github/workflows/docs-screenshots.yml",
    "Scripts/build-test-app.sh",
    "Scripts/capture-doc-screenshots.sh",
    "Scripts/documentation-screenshots-needed.py",
    "Scripts/normalize-doc-screenshot-corners.swift",
    "Scripts/run-ui-tests.sh",
    "UITests/DocumentationScreenshots.xctestplan",
    "UITests/NeoAnki2UITests/DocumentationScreenshotTests.swift",
    "UITests/NeoAnki2UITests/UITestHelpers.swift",
}
CAPTURE_INPUT_PREFIXES = (
    "UITests/NeoAnki2UITests.xcodeproj/",
)


def git(*arguments: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(ROOT), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(arguments)} failed")
    return result.stdout.strip()


def file_at_revision(revision: str, path: str) -> dict[str, object] | None:
    result = subprocess.run(
        ["git", "-C", str(ROOT), "show", f"{revision}:{path}"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if result.returncode != 0:
        return None
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def capture_needed(revision: str) -> tuple[bool, list[str]]:
    features = file_at_revision(revision, "docs/features.json")
    screenshot_manifest = file_at_revision(
        revision, "docs/assets/screenshots/manifest.json"
    )
    if features is None or screenshot_manifest is None:
        return True, ["missing or invalid screenshot metadata"]

    source_sha = screenshot_manifest.get("sourceSHA")
    if not isinstance(source_sha, str) or len(source_sha) != 40:
        return True, ["invalid screenshot source revision"]
    commit_exists = subprocess.run(
        ["git", "-C", str(ROOT), "cat-file", "-e", f"{source_sha}^{{commit}}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0
    if not commit_exists:
        return True, ["screenshot source revision is unavailable"]

    captured_features = file_at_revision(source_sha, "docs/features.json")
    if captured_features is None:
        return True, ["feature metadata at the screenshot source is unavailable"]

    def screenshot_configuration(document: dict[str, object]) -> tuple[object, ...]:
        entries = document.get("features")
        if not isinstance(entries, list):
            return ()
        configured = []
        for entry in entries:
            if not isinstance(entry, dict) or not entry.get("screenshot"):
                continue
            configured.append(
                (entry.get("id"), entry.get("screenshot"), entry.get("sources"))
            )
        return (document.get("requiredScreenshotFeatureIDs"), configured)

    changed = set(
        filter(None, git("diff", "--name-only", source_sha, revision, "--").splitlines())
    )
    screenshot_sources: set[str] = set()
    feature_entries = features.get("features")
    if not isinstance(feature_entries, list):
        return True, ["invalid feature metadata"]
    for feature in feature_entries:
        if not isinstance(feature, dict) or not feature.get("screenshot"):
            continue
        sources = feature.get("sources")
        if isinstance(sources, list):
            screenshot_sources.update(path for path in sources if isinstance(path, str))

    reasons = sorted(changed.intersection(screenshot_sources | CAPTURE_INPUT_FILES))
    if screenshot_configuration(captured_features) != screenshot_configuration(features):
        reasons.append("docs/features.json")
    reasons.extend(
        sorted(
            path
            for path in changed
            if path not in reasons
            and any(path.startswith(prefix) for prefix in CAPTURE_INPUT_PREFIXES)
        )
    )
    return bool(reasons), reasons


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--explain", action="store_true")
    arguments = parser.parse_args()

    needed, reasons = capture_needed(arguments.revision)
    print("true" if needed else "false")
    if arguments.explain:
        for reason in reasons:
            print(reason)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
