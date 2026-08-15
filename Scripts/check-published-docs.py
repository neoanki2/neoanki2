#!/usr/bin/env python3
"""Wait for and smoke-test the canonical documentation deployment."""

from __future__ import annotations

import argparse
import time
import urllib.error
import urllib.request
from pathlib import Path


BASE_URL = "https://neoanki2.github.io"
ROUTES = ("/api/", "/api/decks/")


def fetch(path: str) -> bytes:
    request = urllib.request.Request(
        BASE_URL + path,
        headers={"User-Agent": "neoanki2-docs-smoke/1"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        if response.status != 200:
            raise RuntimeError(f"{path} returned HTTP {response.status}")
        return response.read()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--attempts", type=int, default=40)
    parser.add_argument("--interval", type=float, default=15)
    args = parser.parse_args()

    expected_openapi = Path("docs/api/openapi.json").read_bytes()
    expected_revision = f"/tree/{args.expected_sha}/docs".encode()
    last_error = "deployment did not become visible"

    for attempt in range(1, args.attempts + 1):
        try:
            homepage = fetch("/")
            if expected_revision not in homepage:
                raise RuntimeError("site footer still exposes another source revision")
            for route in ROUTES:
                fetch(route)
            if fetch("/api/openapi.json") != expected_openapi:
                raise RuntimeError("published OpenAPI bytes differ from the validated artifact")
            print(f"Canonical documentation exposes validated revision {args.expected_sha}.")
            return 0
        except (OSError, RuntimeError, urllib.error.URLError) as error:
            last_error = str(error)
            if attempt < args.attempts:
                time.sleep(args.interval)

    print(f"error: canonical documentation smoke test failed: {last_error}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
