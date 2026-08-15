#!/usr/bin/env python3
"""Check external documentation links in a scheduled, network-tolerant job."""

from __future__ import annotations

import concurrent.futures
import re
import urllib.error
import urllib.request
from pathlib import Path


URL_PATTERN = re.compile(r"https?://[^\s)\]<>\"']+")


def check(url: str) -> str | None:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "neoanki2-docs-link-check/1", "Range": "bytes=0-1023"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status >= 400:
                return f"{url}: HTTP {response.status}"
    except (OSError, urllib.error.URLError) as error:
        return f"{url}: {error}"
    return None


def main() -> int:
    urls: set[str] = set()
    for path in Path("docs").rglob("*.md"):
        text = path.read_text(encoding="utf-8")
        for match in URL_PATTERN.finditer(text):
            url = match.group(0).rstrip(".,;:")
            if "{{" not in url:
                urls.add(url)

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        failures = sorted(filter(None, executor.map(check, sorted(urls))))
    for failure in failures:
        print(f"error: {failure}")
    print(f"Checked {len(urls)} external documentation links.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
