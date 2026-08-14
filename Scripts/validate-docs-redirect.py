#!/usr/bin/env python3
"""Validate that a legacy Pages artifact contains redirects, not copied docs."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from urllib.parse import urlsplit


def route_for_file(relative: Path) -> str:
    value = relative.as_posix()
    if value == "index.html":
        return "/"
    if value.endswith("/index.html"):
        return "/" + value[: -len("index.html")]
    return "/" + value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("canonical_site")
    parser.add_argument("redirect_site")
    parser.add_argument("--canonical-base", required=True)
    args = parser.parse_args()

    canonical = Path(args.canonical_site).resolve()
    redirects = Path(args.redirect_site).resolve()
    base = args.canonical_base.rstrip("/")
    split = urlsplit(base)
    errors: list[str] = []
    if split.scheme != "https" or not split.netloc or split.query or split.fragment:
        errors.append("canonical base must be an absolute HTTPS URL")

    expected_pages = {
        page.relative_to(canonical)
        for page in canonical.rglob("*.html")
        if page.relative_to(canonical).as_posix() != "404.html"
    }
    actual_pages = {
        page.relative_to(redirects)
        for page in redirects.rglob("*.html")
        if page.relative_to(redirects).as_posix() != "404.html"
    }
    if actual_pages != expected_pages:
        missing = sorted(path.as_posix() for path in expected_pages - actual_pages)
        extra = sorted(path.as_posix() for path in actual_pages - expected_pages)
        if missing:
            errors.append("missing redirects: " + ", ".join(missing))
        if extra:
            errors.append("unexpected redirect pages: " + ", ".join(extra))

    for relative in sorted(actual_pages):
        route = route_for_file(relative)
        expected = base + ("/" if route == "/" else route)
        text = (redirects / relative).read_text(encoding="utf-8")
        canonical_matches = re.findall(
            r'<link rel="canonical" href="([^"]+)">', text
        )
        refresh_matches = re.findall(
            r'<meta http-equiv="refresh" content="0; url=([^"]+)">', text
        )
        if canonical_matches != [expected] or refresh_matches != [expected]:
            errors.append(f"{relative}: redirect target is not exactly {expected}")
        if "location.replace(" not in text or "noindex,follow" not in text:
            errors.append(f"{relative}: missing script fallback or noindex directive")

    fallback = redirects / "404.html"
    if not fallback.is_file():
        errors.append("missing redirect 404.html")
    else:
        fallback_text = fallback.read_text(encoding="utf-8")
        for required in ("legacyPrefix", "location.pathname", "location.replace("):
            if required not in fallback_text:
                errors.append(f"404.html: missing {required}")

    copied_assets = [
        path for path in redirects.rglob("*")
        if path.is_file() and path.suffix.lower() not in {".html", ""}
    ]
    if copied_assets:
        errors.append(
            "legacy artifact contains copied non-HTML assets: "
            + ", ".join(path.relative_to(redirects).as_posix() for path in copied_assets)
        )

    if errors:
        for error in errors:
            print(f"error: {error}")
        return 1
    print(f"Legacy redirect validation passed ({len(actual_pages)} routes).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
