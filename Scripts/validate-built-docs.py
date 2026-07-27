#!/usr/bin/env python3
"""Validate the rendered output of the NeoAnki2 Jekyll documentation site."""

from __future__ import annotations

import argparse
import posixpath
import re
import sys
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit, urlunsplit


@dataclass(frozen=True)
class Reference:
    value: str
    line: int
    kind: str


@dataclass
class Document:
    path: Path
    route: str
    ids: dict[str, int]
    references: list[Reference]
    canonicals: list[Reference]
    headings: list[tuple[int, int]]
    landmarks: dict[str, list[int]]
    html_langs: list[tuple[str | None, int]]


class DocumentParser(HTMLParser):
    """Collect validation-relevant HTML without third-party dependencies."""

    def __init__(self, path: Path, route: str) -> None:
        super().__init__(convert_charrefs=True)
        self.document = Document(
            path=path,
            route=route,
            ids={},
            references=[],
            canonicals=[],
            headings=[],
            landmarks={name: [] for name in ("header", "nav", "main", "footer")},
            html_langs=[],
        )
        self.duplicate_ids: list[tuple[str, int, int]] = []
        self.named_anchors: set[str] = set()

    def handle_starttag(
        self, tag: str, attrs_list: list[tuple[str, str | None]]
    ) -> None:
        tag = tag.lower()
        attrs = {name.lower(): value for name, value in attrs_list}
        line = self.getpos()[0]

        identifier = attrs.get("id")
        if identifier is not None:
            identifier = identifier.strip()
            if not identifier:
                self.duplicate_ids.append(("(empty ID)", line, line))
            elif identifier in self.document.ids:
                self.duplicate_ids.append(
                    (identifier, line, self.document.ids[identifier])
                )
            else:
                self.document.ids[identifier] = line

        if tag == "html":
            self.document.html_langs.append((attrs.get("lang"), line))
        if tag == "a" and attrs.get("name"):
            self.named_anchors.add(attrs["name"].strip())
        if tag in self.document.landmarks:
            self.document.landmarks[tag].append(line)
        if re.fullmatch(r"h[1-6]", tag):
            self.document.headings.append((int(tag[1]), line))

        if tag == "img":
            alt = attrs.get("alt")
            if alt is None or not alt.strip():
                self._error_marker("image-alt", line)

        reference_attributes = {
            "a": ("href", "route"),
            "area": ("href", "route"),
            "img": ("src", "asset"),
            "script": ("src", "asset"),
            "source": ("src", "asset"),
            "audio": ("src", "asset"),
            "video": ("src", "asset"),
            "track": ("src", "asset"),
            "object": ("data", "asset"),
        }
        if tag in reference_attributes:
            attribute, kind = reference_attributes[tag]
            value = attrs.get(attribute)
            if value:
                self.document.references.append(Reference(value.strip(), line, kind))

        if tag == "video" and attrs.get("poster"):
            self.document.references.append(
                Reference(attrs["poster"].strip(), line, "asset")
            )

        if tag in {"img", "source"} and attrs.get("srcset"):
            for candidate in attrs["srcset"].split(","):
                url = candidate.strip().split(maxsplit=1)[0]
                if url:
                    self.document.references.append(Reference(url, line, "asset"))

        if tag == "link" and attrs.get("href"):
            rel = set((attrs.get("rel") or "").lower().split())
            reference = Reference(attrs["href"].strip(), line, "asset")
            if "canonical" in rel:
                self.document.canonicals.append(reference)
            else:
                self.document.references.append(reference)

    def handle_startendtag(
        self, tag: str, attrs_list: list[tuple[str, str | None]]
    ) -> None:
        self.handle_starttag(tag, attrs_list)

    def _error_marker(self, kind: str, line: int) -> None:
        self.document.references.append(Reference("", line, kind))


def route_for_file(relative_path: Path) -> str:
    value = relative_path.as_posix()
    if value == "index.html":
        return "/"
    if value.endswith("/index.html"):
        return "/" + value[: -len("index.html")]
    return "/" + value


def normalized_base_url(value: str) -> str:
    split = urlsplit(value)
    if split.scheme not in {"http", "https"} or not split.netloc:
        raise ValueError("--base-url must be an absolute HTTP(S) URL")
    if split.query or split.fragment:
        raise ValueError("--base-url must not contain a query or fragment")
    path = split.path.rstrip("/")
    return urlunsplit((split.scheme, split.netloc, path, "", ""))


def route_to_file(site: Path, route_path: str) -> Path | None:
    decoded = unquote(route_path)
    if "\x00" in decoded:
        return None
    relative = decoded.lstrip("/")
    normalized = posixpath.normpath(relative)
    if normalized == ".." or normalized.startswith("../"):
        return None
    if decoded.endswith("/") or not relative:
        candidates = [site / normalized / "index.html"]
    else:
        target = site / normalized
        candidates = [target]
        if not Path(normalized).suffix:
            candidates.extend([target / "index.html", target.with_suffix(".html")])
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def expected_canonical(base_url: str, route: str) -> str:
    return base_url + ("/" if route == "/" else route)


def validate_document(
    document: Document,
    parser: DocumentParser,
    site: Path,
    base_url: str,
    errors: list[str],
) -> None:
    relative = document.path.relative_to(site).as_posix()

    def report(line: int, message: str) -> None:
        errors.append(f"{relative}:{line}: {message}")

    if len(document.html_langs) != 1:
        report(1, f"expected one <html> element, found {len(document.html_langs)}")
    elif not (document.html_langs[0][0] or "").strip():
        report(document.html_langs[0][1], "<html> must have a nonempty lang attribute")

    h1s = [(level, line) for level, line in document.headings if level == 1]
    if len(h1s) != 1:
        report(1, f"expected exactly one <h1>, found {len(h1s)}")
    if document.headings and document.headings[0][0] != 1:
        level, line = document.headings[0]
        report(line, f"first heading must be <h1>, found <h{level}>")
    previous_level = 0
    for level, line in document.headings:
        if previous_level and level > previous_level + 1:
            report(
                line,
                f"heading order skips from <h{previous_level}> to <h{level}>; "
                f"use <h{previous_level + 1}> first",
            )
        previous_level = level

    for landmark, lines in document.landmarks.items():
        if not lines:
            report(1, f"missing basic <{landmark}> landmark")

    for identifier, line, first_line in parser.duplicate_ids:
        if identifier == "(empty ID)":
            report(line, "id attributes must not be empty")
        else:
            report(
                line,
                f'duplicate id "{identifier}" (first declared on line {first_line})',
            )

    for reference in document.references:
        if reference.kind == "image-alt":
            report(reference.line, "image alt text must be present and nonempty")
            continue
        validate_reference(document.route, reference, site, base_url, report)

    if len(document.canonicals) != 1:
        report(
            1,
            f"expected exactly one <link rel=\"canonical\">, "
            f"found {len(document.canonicals)}",
        )
    else:
        canonical = document.canonicals[0]
        split = urlsplit(canonical.value)
        if split.scheme not in {"http", "https"} or not split.netloc:
            report(canonical.line, f'canonical URL must be absolute: "{canonical.value}"')
        elif split.query or split.fragment:
            report(
                canonical.line,
                f'canonical URL must not contain a query or fragment: "{canonical.value}"',
            )
        elif canonical.value != expected_canonical(base_url, document.route):
            report(
                canonical.line,
                f'canonical URL "{canonical.value}" does not match expected '
                f'"{expected_canonical(base_url, document.route)}"',
            )


def validate_reference(
    current_route: str,
    reference: Reference,
    site: Path,
    base_url: str,
    report,
) -> None:
    value = reference.value
    split = urlsplit(value)
    if split.scheme in {"mailto", "tel", "data"}:
        return
    if split.scheme and split.scheme not in {"http", "https"}:
        report(reference.line, f'unsupported or unsafe URL scheme in "{value}"')
        return

    base = urlsplit(base_url)
    if split.netloc and split.netloc != base.netloc:
        return

    current_url = base_url + current_route
    resolved = urlsplit(urljoin(current_url, value))
    if resolved.netloc != base.netloc:
        return

    base_path = base.path.rstrip("/")
    route_path = resolved.path
    if base_path and route_path != base_path and not route_path.startswith(base_path + "/"):
        report(
            reference.line,
            f'internal URL escapes the configured base path "{base_path}": "{value}"',
        )
        return
    site_path = route_path[len(base_path) :] if base_path else route_path
    target = route_to_file(site, site_path or "/")
    if target is None:
        report(reference.line, f'broken internal {reference.kind} URL: "{value}"')
        return

    fragment = unquote(resolved.fragment)
    if fragment and target.suffix.lower() == ".html":
        target_document = parse_document(target, site)
        if (
            fragment not in target_document.document.ids
            and fragment not in target_document.named_anchors
        ):
            report(
                reference.line,
                f'fragment "#{fragment}" does not exist in '
                f"{target.relative_to(site).as_posix()}",
            )


def validate_css_assets(site: Path, base_url: str, errors: list[str]) -> None:
    """Validate local assets referenced from rendered stylesheets."""
    url_pattern = re.compile(r"""url\(\s*(?P<quote>["']?)(?P<url>.*?)\1\s*\)""")
    import_pattern = re.compile(r"""@import\s+(?P<quote>["'])(?P<url>.*?)\1""")
    for stylesheet in sorted(site.rglob("*.css")):
        relative = stylesheet.relative_to(site).as_posix()
        try:
            contents = stylesheet.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            errors.append(f"{relative}:1: could not read rendered stylesheet: {error}")
            continue

        def report(line: int, message: str) -> None:
            errors.append(f"{relative}:{line}: {message}")

        matches = list(url_pattern.finditer(contents))
        matches.extend(import_pattern.finditer(contents))
        for match in sorted(matches, key=lambda item: item.start()):
            value = match.group("url").strip()
            if not value or value.startswith("#"):
                continue
            line = contents.count("\n", 0, match.start()) + 1
            validate_reference(
                "/" + relative,
                Reference(value, line, "asset"),
                site,
                base_url,
                report,
            )


_PARSE_CACHE: dict[Path, DocumentParser] = {}


def parse_document(path: Path, site: Path) -> DocumentParser:
    if path in _PARSE_CACHE:
        return _PARSE_CACHE[path]
    parser = DocumentParser(path, route_for_file(path.relative_to(site)))
    try:
        parser.feed(path.read_text(encoding="utf-8"))
        parser.close()
    except (OSError, UnicodeError) as error:
        raise ValueError(f"could not read rendered HTML: {error}") from error
    _PARSE_CACHE[path] = parser
    return parser


def main() -> int:
    argument_parser = argparse.ArgumentParser(
        description="Crawl and validate a rendered Jekyll _site directory."
    )
    argument_parser.add_argument(
        "site", nargs="?", default="_site", help="built site directory (default: _site)"
    )
    argument_parser.add_argument(
        "--base-url",
        required=True,
        help="published site URL, including any base path",
    )
    args = argument_parser.parse_args()

    site = Path(args.site).resolve()
    if not site.is_dir():
        print(f"ERROR: built site directory does not exist: {site}", file=sys.stderr)
        return 2
    try:
        base_url = normalized_base_url(args.base_url)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    html_files = sorted(site.rglob("*.html"))
    if not html_files:
        print(f"ERROR: no rendered HTML files found under {site}", file=sys.stderr)
        return 2

    errors: list[str] = []
    canonical_owners: dict[str, str] = {}
    for html_file in html_files:
        try:
            parser = parse_document(html_file, site)
        except ValueError as error:
            errors.append(f"{html_file.relative_to(site)}:1: {error}")
            continue
        validate_document(parser.document, parser, site, base_url, errors)
        if len(parser.document.canonicals) == 1:
            canonical = parser.document.canonicals[0].value.rstrip("/")
            owner = canonical_owners.get(canonical)
            relative = html_file.relative_to(site).as_posix()
            if owner:
                errors.append(
                    f"{relative}:1: duplicate canonical URL also used by {owner}: "
                    f'"{canonical}"'
                )
            else:
                canonical_owners[canonical] = relative

    validate_css_assets(site, base_url, errors)

    if errors:
        print(
            f"Rendered documentation validation failed with {len(errors)} error(s):",
            file=sys.stderr,
        )
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(
        f"Validated {len(html_files)} rendered HTML page(s) under {site} "
        f"against {base_url}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
