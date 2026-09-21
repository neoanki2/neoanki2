#!/usr/bin/env python3
"""Check external documentation links in a scheduled, network-tolerant job."""

from __future__ import annotations

import concurrent.futures
import http.client
import ipaddress
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable


URL_PATTERN = re.compile(r"https?://[^\s)\]<>\"']+")
TRAILING_MARKUP = "`.,;:!?)]}"
NON_PUBLIC_SUFFIXES = (".example", ".invalid", ".local", ".localhost", ".test")
RETRYABLE_HTTP_STATUSES = {408, 425, 429, 500, 502, 503, 504}


def is_public_http_url(url: str) -> bool:
    """Return whether a URL is a well-formed public HTTP(S) target."""
    try:
        parsed = urllib.parse.urlsplit(url)
        hostname = parsed.hostname
        # Reading port validates malformed authorities such as ``:8766` ``.
        parsed.port
    except ValueError:
        return False
    if parsed.scheme not in {"http", "https"} or not hostname:
        return False

    hostname = hostname.rstrip(".").lower()
    if hostname == "localhost" or hostname.endswith(NON_PUBLIC_SUFFIXES):
        return False
    try:
        return ipaddress.ip_address(hostname).is_global
    except ValueError:
        return True


def external_urls(root: Path) -> set[str]:
    """Extract public links while ignoring examples and local API snippets."""
    urls: set[str] = set()
    for path in root.rglob("*.md"):
        text = path.read_text(encoding="utf-8")
        for match in URL_PATTERN.finditer(text):
            url = match.group(0).rstrip(TRAILING_MARKUP)
            if "{{" not in url and is_public_http_url(url):
                urls.add(url)
    return urls


class PublicRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Prevent public documentation links from redirecting to local services."""

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        if not is_public_http_url(new_url):
            raise urllib.error.URLError(
                f"refusing redirect to non-public URL: {new_url}"
            )
        return super().redirect_request(
            request,
            file_pointer,
            307 if code == 308 else code,
            message,
            headers,
            new_url,
        )

    # Python 3.9 does not yet provide the RFC 7538 permanent-redirect alias.
    http_error_308 = urllib.request.HTTPRedirectHandler.http_error_302


def check(
    url: str,
    *,
    attempts: int = 3,
    timeout: float = 30,
    open_url: Callable[..., object] | None = None,
    sleep: Callable[[float], None] = time.sleep,
) -> str | None:
    if not is_public_http_url(url):
        return f"{url}: invalid or non-public URL"

    opener = urllib.request.build_opener(PublicRedirectHandler())
    open_request = open_url or opener.open
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "neoanki2-docs-link-check/1", "Range": "bytes=0-1023"},
    )
    for attempt in range(1, attempts + 1):
        try:
            with open_request(request, timeout=timeout) as response:
                if response.status >= 400:
                    return f"{url}: HTTP {response.status}"
            return None
        except urllib.error.HTTPError as error:
            if error.code not in RETRYABLE_HTTP_STATUSES or attempt == attempts:
                return f"{url}: HTTP {error.code}"
        except (http.client.InvalidURL, OSError, ValueError, urllib.error.URLError) as error:
            if attempt == attempts:
                return f"{url}: {error}"
        sleep(float(2 ** (attempt - 1)))
    return f"{url}: exhausted retries"


def main() -> int:
    urls = external_urls(Path("docs"))

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        failures = sorted(filter(None, executor.map(check, sorted(urls))))
    for failure in failures:
        print(f"error: {failure}")
    print(f"Checked {len(urls)} external documentation links.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
