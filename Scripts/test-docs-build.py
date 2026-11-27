#!/usr/bin/env python3
"""Build and verify the GitHub Pages artifacts without publishing them."""

import argparse
import datetime
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading


ROOT = Path(__file__).resolve().parent.parent
CANONICAL_URL = "https://neoanki2.github.io"
# GitHub Pages Jekyll v1.0.13, pinned for both the hook and the publish workflow.
PAGES_IMAGE = "ghcr.io/actions/jekyll-build-pages@sha256:6791ebfd912185ed59bfb5fb102664fa872496b79f87ff8b9cfba292a7345041"
PLAYWRIGHT_VERSION = "1.62.1"
SITE_INPUTS = (
    "docs",
    ".github/workflows/docs-pages.yml",
    "Scripts/test-docs-build.py",
    "Scripts/validate-built-docs.py",
    "Scripts/check-docs-responsive.mjs",
    "Scripts/build-docs-redirect.py",
    "Scripts/validate-docs-redirect.py",
    "Scripts/check-published-docs.py",
)


def run(*args, **kwargs):
    subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def site_changed(base):
    result = subprocess.check_output(
        ("git", "diff", "--name-only", base, "HEAD", "--", *SITE_INPUTS), cwd=ROOT
    )
    return bool(result)


def render(directory):
    runners = ("docker", "podman") if os.environ.get("GITHUB_ACTIONS") == "true" else ("podman", "docker")
    runtime = next((path for name in runners if (path := shutil.which(name))), None)
    if not runtime:
        raise RuntimeError("The local Pages build needs a running Podman or Docker engine.")
    # Render the committed docs. Ignored files in a local checkout are not CI inputs.
    archive = directory / "source.tar"
    run("git", "archive", "--format=tar", f"--output={archive}", "HEAD", "docs")
    run("tar", "-xf", str(archive), "-C", str(directory))
    archive.unlink()
    data = directory / "docs" / "_data"
    data.mkdir(exist_ok=True)
    revision = subprocess.check_output(("git", "rev-parse", "HEAD"), cwd=ROOT, text=True).strip()
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    (data / "build.json").write_text(
        json.dumps({"commit_sha": revision, "published_at": timestamp}) + "\n", encoding="utf-8"
    )
    run(
        runtime, "run", "--rm", "--platform", "linux/amd64",
        "--user", f"{os.getuid()}:{os.getgid()}",
        "-e", "HOME=/tmp", "-e", "INPUT_TOKEN",
        "-v", f"{directory}:/github/workspace",
        "-e", "GITHUB_WORKSPACE=/github/workspace",
        "-e", "GITHUB_REPOSITORY=neoanki2/neoanki2",
        "-e", "GITHUB_API_URL=https://api.github.com",
        "-e", "INPUT_SOURCE=docs",
        "-e", "INPUT_DESTINATION=site",
        "-e", "INPUT_VERBOSE=true",
        "-e", f"INPUT_BUILD_REVISION={revision}",
        PAGES_IMAGE,
    )
    return directory / "site"


def check_responsive(site):
    playwright = ROOT / ".build" / "docs-playwright" / PLAYWRIGHT_VERSION
    package = playwright / "node_modules" / "playwright"
    if not (package / "index.mjs").is_file():
        run("npm", "install", "--prefix", str(playwright), "--no-save", "--no-package-lock",
            f"playwright@{PLAYWRIGHT_VERSION}")
    install_args = ["--with-deps"] if os.environ.get("GITHUB_ACTIONS") == "true" else []
    run("node", str(package / "cli.js"), "install", "--only-shell", *install_args, "chromium")
    handler = partial(SimpleHTTPRequestHandler, directory=str(site))
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        serving = threading.Thread(target=server.serve_forever, daemon=True)
        serving.start()
        try:
            run(
                "node", "Scripts/check-docs-responsive.mjs", f"http://127.0.0.1:{server.server_port}",
                env={**os.environ, "PLAYWRIGHT_MODULE": (package / "index.mjs").as_uri()},
            )
        finally:
            server.shutdown()
            serving.join()


def validate(site, redirects):
    run(sys.executable, "Scripts/validate-built-docs.py", str(site), "--base-url", CANONICAL_URL)
    check_responsive(site)
    run(
        sys.executable, "Scripts/build-docs-redirect.py", str(site), str(redirects),
        "--canonical-base", CANONICAL_URL, "--legacy-prefix", "/neoanki2",
    )
    run(
        sys.executable, "Scripts/validate-docs-redirect.py", str(site), str(redirects),
        "--canonical-base", CANONICAL_URL,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--base", help="build only when site inputs differ from this revision")
    mode.add_argument("--changed", metavar="BASE", help="print whether site inputs changed")
    parser.add_argument("--redirect-site", type=Path, help="retain the verified redirects for deployment")
    args = parser.parse_args()
    if args.changed:
        print(str(site_changed(args.changed)).lower())
    elif args.base and not site_changed(args.base):
        print("Documentation build skipped because the site inputs match main.")
    else:
        scratch = ROOT / ".build"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="docs-build-", dir=scratch) as folder:
            directory = Path(folder)
            redirects = directory / "redirects"
            validate(render(directory), redirects)
            if args.redirect_site:
                shutil.copytree(redirects, args.redirect_site)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"Documentation build failed: {error}")
