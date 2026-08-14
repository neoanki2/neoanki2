#!/usr/bin/env python3
"""Build a compatibility-only Pages site that redirects to canonical docs."""

from __future__ import annotations

import argparse
import html
import json
import shutil
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit


def normalized_url(value: str) -> str:
    split = urlsplit(value)
    if split.scheme != "https" or not split.netloc or split.query or split.fragment:
        raise ValueError("canonical base must be an absolute HTTPS URL without query or fragment")
    return urlunsplit((split.scheme, split.netloc, split.path.rstrip("/"), "", ""))


def route_for_file(relative: Path) -> str:
    value = relative.as_posix()
    if value == "index.html":
        return "/"
    if value.endswith("/index.html"):
        return "/" + value[: -len("index.html")]
    return "/" + value


def redirect_document(target: str) -> str:
    escaped = html.escape(target, quote=True)
    encoded = json.dumps(target)
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex,follow">
    <meta http-equiv="refresh" content="0; url={escaped}">
    <link rel="canonical" href="{escaped}">
    <title>NeoAnki2 documentation moved</title>
  </head>
  <body>
    <main>
      <h1>NeoAnki2 documentation moved</h1>
      <p><a href="{escaped}">Continue to the canonical guide.</a></p>
    </main>
    <script>location.replace({encoded} + location.search + location.hash);</script>
  </body>
</html>
"""


def not_found_document(canonical_base: str, legacy_prefix: str) -> str:
    root = html.escape(canonical_base + "/", quote=True)
    base_json = json.dumps(canonical_base)
    prefix_json = json.dumps(legacy_prefix)
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex,follow">
    <meta http-equiv="refresh" content="0; url={root}">
    <link rel="canonical" href="{root}">
    <title>NeoAnki2 documentation moved</title>
  </head>
  <body>
    <main>
      <h1>NeoAnki2 documentation moved</h1>
      <p><a href="{root}">Continue to the canonical documentation.</a></p>
    </main>
    <script>
      const canonicalBase = {base_json};
      const legacyPrefix = {prefix_json};
      let path = location.pathname;
      if (path === legacyPrefix) path = "/";
      else if (path.startsWith(legacyPrefix + "/")) path = path.slice(legacyPrefix.length);
      else path = "/";
      location.replace(canonicalBase + path + location.search + location.hash);
    </script>
  </body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", help="validated canonical Jekyll output")
    parser.add_argument("destination", help="compatibility redirect output")
    parser.add_argument("--canonical-base", required=True)
    parser.add_argument("--legacy-prefix", required=True)
    args = parser.parse_args()

    source = Path(args.source).resolve()
    destination = Path(args.destination).resolve()
    canonical_base = normalized_url(args.canonical_base)
    legacy_prefix = "/" + args.legacy_prefix.strip("/")
    if not source.is_dir() or not (source / "index.html").is_file():
        raise SystemExit(f"canonical site is missing: {source}")
    if destination == source or source in destination.parents:
        raise SystemExit("redirect destination must be separate from canonical output")

    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)

    count = 0
    for page in sorted(source.rglob("*.html")):
        relative = page.relative_to(source)
        if relative.as_posix() == "404.html":
            continue
        route = route_for_file(relative)
        target = canonical_base + ("/" if route == "/" else route)
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(redirect_document(target), encoding="utf-8")
        count += 1

    (destination / "404.html").write_text(
        not_found_document(canonical_base, legacy_prefix), encoding="utf-8"
    )
    (destination / ".nojekyll").write_text("", encoding="utf-8")
    print(f"Built {count} legacy route redirects plus 404 fallback in {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
