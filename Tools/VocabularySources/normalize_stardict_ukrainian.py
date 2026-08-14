#!/usr/bin/env python3
"""Normalize selected local StarDict Ukrainian dictionaries for NeoAnki.

The adapter performs no network access. It reads the locked StarDict archive
directly, preserves source text and record offsets, and writes newline-delimited
NeoAnkiVocabularyKit LexicalEntry JSON.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import pathlib
import re
import struct
import sys
import unicodedata
import zipfile
from collections.abc import Iterator
from typing import Any


SUM_INDEX_SUFFIX = "ukr-ukr_SUM-11_or_1/sum.idx"
SUM_DICT_SUFFIX = "ukr-ukr_SUM-11_or_1/sum.dict"
RUUK_INDEX_FRAGMENT = "ru-uk_velykyi_ros-uk_slovnyk/"
RUUK_INDEX_SUFFIX = ".idx"
RUUK_DICT_SUFFIX = ".dict"
SOURCE_URL = (
    "https://github.com/bakustarver/ukr-dictionaries-list-opensource/"
    "releases/download/0.1/Stardict.Ukr.zip"
)
BLOCK_TAG_RE = re.compile(r"</?(?:div|p|br|li|ul|ol|hr)\b[^>]*>", re.IGNORECASE)
TAG_RE = re.compile(r"<[^>]+>")
TOP_LEVEL_DIV_RE = re.compile(
    r'<div\s+style="margin-left:1em">(.*?)</div>', re.IGNORECASE | re.DOTALL
)
EXAMPLE_DIV_RE = re.compile(
    r'<div\s+style="margin-left:(?:2|3)em">(.*?)</div>', re.IGNORECASE | re.DOTALL
)
ITALIC_RE = re.compile(r"<i\b[^>]*>.*?</i>", re.IGNORECASE | re.DOTALL)
EXAMPLE_SPAN_RE = re.compile(
    r'<span\b[^>]*class="[^"]*(?:ex|sec)[^"]*"[^>]*>.*?</span>',
    re.IGNORECASE | re.DOTALL,
)
BOLD_RE = re.compile(r"<b\b[^>]*>(.*?)</b>", re.IGNORECASE | re.DOTALL)
CYRILLIC_RE = re.compile(r"[А-Яа-яІіЇїЄєҐґ]")
WORD_RE = re.compile(r"[А-Яа-яІіЇїЄєҐґ'’\-]+")
SUPERSCRIPTS = str.maketrans({character: None for character in "¹²³⁴⁵⁶⁷⁸⁹⁰"})


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_id(kind: str, value: Any) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return f"{kind}-{hashlib.sha256(encoded).hexdigest()[:24]}"


def clean_html(value: str) -> str:
    value = BLOCK_TAG_RE.sub("\n", value)
    value = TAG_RE.sub("", value)
    value = html.unescape(value).replace("\xa0", " ")
    lines = [" ".join(line.split()) for line in value.splitlines()]
    return "\n".join(line for line in lines if line)


def plain_inline(value: str) -> str:
    return " ".join(clean_html(value).split())


def normalized_lookup(value: str) -> str:
    decomposed = unicodedata.normalize("NFD", value)
    return unicodedata.normalize(
        "NFC", "".join(character for character in decomposed if character != "\u0301")
    ).casefold()


def find_member(names: list[str], *, suffix: str | None = None, fragment: str | None = None) -> str:
    matches = [
        name
        for name in names
        if (suffix is None or name.endswith(suffix))
        and (fragment is None or fragment in name)
    ]
    if len(matches) != 1:
        raise ValueError(
            f"expected one archive member for suffix={suffix!r} fragment={fragment!r}; "
            f"found {len(matches)}"
        )
    return matches[0]


def stardict_records(index_bytes: bytes, dictionary_bytes: bytes) -> Iterator[tuple[str, str, int, int]]:
    cursor = 0
    while cursor < len(index_bytes):
        terminator = index_bytes.find(b"\0", cursor)
        if terminator < 0 or terminator + 9 > len(index_bytes):
            raise ValueError(f"malformed StarDict index at byte {cursor}")
        word = index_bytes[cursor:terminator].decode("utf-8")
        offset, size = struct.unpack(">II", index_bytes[terminator + 1 : terminator + 9])
        if offset + size > len(dictionary_bytes):
            raise ValueError(f"StarDict record outside dictionary: {word!r}")
        article = dictionary_bytes[offset : offset + size].decode("utf-8")
        yield word, article, offset, size
        cursor = terminator + 9


def provenance(source_id: str, record_id: str, archive_digest: str) -> dict[str, str]:
    del archive_digest
    return {
        "sourceID": source_id,
        "recordID": record_id,
    }


def localized(value: str, language: str) -> dict[str, str]:
    return {"value": value, "language": language}


def text_pronunciation(value: str, source: dict[str, str]) -> dict[str, Any]:
    return {
        "id": stable_id("pronunciation", {"value": value, "record": source["recordID"]}),
        "scheme": "orthographic-respelling",
        "label": "Dictionary headword with stress",
        "representations": [{"text": {"_0": localized(value, "uk")}}],
        "formIDs": ["canonical"],
        "provenance": source,
    }


def sum_head_definition(first_div: str) -> str | None:
    closing_italics = list(re.finditer(r"</i>", first_div, re.IGNORECASE))
    if closing_italics:
        candidate = plain_inline(first_div[closing_italics[-1].end() :]).lstrip(" ,.;:—-")
        if candidate:
            return candidate
        return None
    bold = BOLD_RE.search(first_div)
    if bold:
        candidate = plain_inline(first_div[bold.end() :]).lstrip(" ,.;:—-")
        if candidate:
            return candidate
    return None


def sum_dictionary_header(first_div: str) -> str | None:
    closing_italics = list(re.finditer(r"</i>", first_div, re.IGNORECASE))
    if closing_italics:
        header = plain_inline(first_div[: closing_italics[-1].end()]).strip(" ,;:—-")
        return header or None
    bold = BOLD_RE.search(first_div)
    if bold:
        header = plain_inline(first_div[: bold.end()]).strip(" ,;:—-")
        return header or None
    return None


def normalize_sum_entry(
    word: str, article: str, offset: int, size: int, archive_digest: str
) -> dict[str, Any] | None:
    word = unicodedata.normalize("NFC", word.strip())
    if not word or not CYRILLIC_RE.search(word):
        return None
    record_id = f"sum11:{offset}:{size}"
    source = provenance("stardict-sum11", record_id, archive_digest)
    article_text = clean_html(article)
    if not article_text:
        return None
    top_level_divs = list(TOP_LEVEL_DIV_RE.finditer(article))
    first_div_match = top_level_divs[0] if top_level_divs else None
    dictionary_header = sum_dictionary_header(first_div_match.group(1)) if first_div_match else None
    head_definition = sum_head_definition(first_div_match.group(1)) if first_div_match else None
    if not head_definition:
        for candidate_match in top_level_divs[1:]:
            candidate = plain_inline(candidate_match.group(1)).lstrip("/♦◊ ")
            if candidate:
                head_definition = candidate
                break
    if not head_definition:
        head_definition = article_text.splitlines()[0]
    definitions: list[dict[str, Any]] = []
    definitions.append(
        {
                "id": stable_id("definition-head", {"text": head_definition, "record": record_id}),
                "text": localized(head_definition, "uk"),
            }
    )

    forms: list[dict[str, Any]] = []
    bold = BOLD_RE.search(first_div_match.group(1) if first_div_match else article)
    if bold:
        stressed = plain_inline(bold.group(1)).translate(SUPERSCRIPTS).strip(" ,.;:—-")
        stressed_lookup = normalized_lookup(stressed)
        if stressed and stressed_lookup == normalized_lookup(word):
            forms.append(
                {
                    "id": "stressed-headword",
                    "text": localized(stressed, "uk"),
                    "kind": "stressed",
                    "grammaticalFeatures": [],
                }
            )

    canonical = {
        "id": "canonical",
        "text": localized(word, "uk"),
        "kind": "lemma",
        "grammaticalFeatures": (
            [{"name": "dictionaryHeader", "value": dictionary_header}]
            if dictionary_header
            else []
        ),
    }
    return {
        "id": stable_id("stardict-sum11", {"word": word, "record": record_id}),
        "language": "uk",
        "canonicalForm": canonical,
        "forms": forms,
        "pronunciations": [],
        "senses": [
            {
                "id": stable_id("sense", {"word": word, "record": record_id}),
                "definitions": definitions,
                "examples": [],
                "labels": [],
            }
        ],
        "provenance": source,
    }


def load_sum_word_set(archive: zipfile.ZipFile, names: list[str]) -> set[str]:
    index_name = find_member(names, suffix=SUM_INDEX_SUFFIX)
    words: set[str] = set()
    index = archive.read(index_name)
    cursor = 0
    while cursor < len(index):
        terminator = index.find(b"\0", cursor)
        if terminator < 0 or terminator + 9 > len(index):
            raise ValueError("malformed SUM-11 StarDict index")
        word = index[cursor:terminator].decode("utf-8").strip()
        if word:
            words.add(normalized_lookup(word))
        cursor = terminator + 9
    return words


def translation_forms(article: str, russian_word: str, sum_words: set[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for match in TOP_LEVEL_DIV_RE.finditer(article):
        fragment = EXAMPLE_SPAN_RE.sub("", match.group(1))
        fragment = ITALIC_RE.sub("", fragment)
        text = plain_inline(fragment).strip(" =")
        if not text or text.startswith(("от слова:", "Краткая форма:", "Деепричастная форма:")):
            continue
        for segment in re.split(r"\s*[;,]\s*", text):
            segment = segment.strip(" .:—-")
            if not segment or len(segment) > 256 or not CYRILLIC_RE.search(segment):
                continue
            tokens = WORD_RE.findall(segment)
            if not tokens:
                continue
            normalized_tokens = [normalized_lookup(token) for token in tokens]
            looks_ukrainian = (
                any(character in segment for character in "іїєґІЇЄҐ")
                or normalized_lookup(segment) == normalized_lookup(russian_word)
                or all(token in sum_words for token in normalized_tokens)
            )
            if not looks_ukrainian:
                continue
            key = normalized_lookup(segment)
            if key in seen:
                continue
            seen.add(key)
            result.append(segment)
    return result


def normalize_ruuk_entry(
    word: str,
    article: str,
    offset: int,
    size: int,
    archive_digest: str,
    sum_words: set[str],
) -> dict[str, Any] | None:
    word = unicodedata.normalize("NFC", word.strip())
    if not word or not CYRILLIC_RE.search(word):
        return None
    translations = translation_forms(article, word, sum_words)
    if not translations:
        return None
    record_id = f"ruuk-big:{offset}:{size}"
    source = provenance("stardict-ruuk-big", record_id, archive_digest)
    forms = [
        {
            "id": stable_id("translation", {"text": value, "record": record_id}),
            "text": localized(value, "uk"),
            "kind": "translation",
            "grammaticalFeatures": [],
        }
        for value in translations[:1000]
    ]
    return {
        "id": stable_id("stardict-ruuk", {"word": word, "record": record_id}),
        "language": "ru",
        "canonicalForm": {
            "id": "canonical",
            "text": localized(word, "ru"),
            "kind": "lemma",
            "grammaticalFeatures": [],
            "provenance": source,
        },
        "forms": forms,
        "pronunciations": [],
        "senses": [],
        "provenance": source,
    }


def normalize(archive_path: pathlib.Path, output_path: pathlib.Path, dictionary: str) -> int:
    archive_digest = sha256(archive_path)
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        if dictionary == "sum11":
            index_name = find_member(names, suffix=SUM_INDEX_SUFFIX)
            dictionary_name = find_member(names, suffix=SUM_DICT_SUFFIX)
            sum_words: set[str] | None = None
        else:
            index_name = find_member(
                names, suffix=RUUK_INDEX_SUFFIX, fragment=RUUK_INDEX_FRAGMENT
            )
            dictionary_name = find_member(
                names, suffix=RUUK_DICT_SUFFIX, fragment=RUUK_INDEX_FRAGMENT
            )
            sum_words = load_sum_word_set(archive, names)
        index_bytes = archive.read(index_name)
        dictionary_bytes = archive.read(dictionary_name)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(output_path.name + ".part")
    count = 0
    with temporary.open("w", encoding="utf-8", newline="\n") as output:
        for word, article, offset, size in stardict_records(index_bytes, dictionary_bytes):
            if dictionary == "sum11":
                entry = normalize_sum_entry(word, article, offset, size, archive_digest)
            else:
                assert sum_words is not None
                entry = normalize_ruuk_entry(
                    word, article, offset, size, archive_digest, sum_words
                )
            if entry is None:
                continue
            output.write(
                json.dumps(entry, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                + "\n"
            )
            count += 1
    temporary.replace(output_path)
    return count


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Normalize locked Ukrainian StarDict sources; performs no downloads."
    )
    parser.add_argument("--input", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--dictionary", required=True, choices=("sum11", "ruuk"))
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    if not arguments.input.is_file():
        raise SystemExit(f"input archive not found: {arguments.input}")
    try:
        count = normalize(arguments.input, arguments.output, arguments.dictionary)
    except (OSError, UnicodeError, ValueError, zipfile.BadZipFile) as error:
        raise SystemExit(f"error: {error}") from error
    print(f"Normalized {count} {arguments.dictionary} entries to {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
