#!/usr/bin/env python3
"""Normalize a local Kaikki/Wiktextract JSONL export for NeoAnki.

This program performs no network access. Inputs may be plain JSONL or gzip-compressed
JSONL. Output is newline-delimited NeoAnkiVocabularyKit LexicalEntry JSON.
"""

from __future__ import annotations

import argparse
import bz2
import gzip
import hashlib
import json
import pathlib
import sys
import unicodedata
import urllib.parse
from collections.abc import Iterable, Iterator
from typing import Any, NamedTuple, TextIO


STRUCTURAL_FORM_TAGS = {"table-tags", "inflection-template", "class"}
PLACEHOLDER_FORMS = {"-"}
MAX_TATOEBA_TOKENS_PER_SENTENCE = 512
MAX_TATOEBA_SENTENCE_CODEPOINTS = 10_000


class CorpusOccurrence(NamedTuple):
    sentence_id: str
    text: str
    target_start: int
    target_length: int
    target_text: str


def list_value(value: Any) -> list[Any]:
    """Treat missing or malformed collection fields as empty source data."""
    return value if isinstance(value, list) else []


def localized(value: str, language: str | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {"value": value}
    if language:
        result["language"] = language
    return result


def provenance(
    *,
    source_id: str,
    source_name: str,
    record_id: str,
    attribution: str,
    license_name: str,
    source_url: str,
) -> dict[str, str]:
    return {
        "sourceID": source_id,
        "sourceName": source_name,
        "recordID": record_id,
        "attribution": attribution,
        "license": license_name,
        "sourceURL": source_url,
    }


def content_digest(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()[:24]


def stable_entry_id(source: dict[str, Any], language: str, line_number: int | None = None) -> str:
    # `line_number` remains accepted for adapter API compatibility but never participates in identity.
    digest = content_digest({"language": language, "source": source})
    return f"kaikki:{language}:{digest}"


def stable_id(kind: str, value: Any) -> str:
    return f"{kind}-{content_digest(value)}"


def parse_codepoint(value: str) -> int:
    normalized = value.strip().upper()
    if normalized.startswith("U+"):
        normalized = normalized[2:]
    elif normalized.startswith("0X"):
        normalized = normalized[2:]
    try:
        result = int(normalized, 16)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid Unicode codepoint: {value}") from error
    if result < 0 or result > 0x10FFFF or 0xD800 <= result <= 0xDFFF:
        raise argparse.ArgumentTypeError(f"invalid Unicode scalar codepoint: {value}")
    if not unicodedata.category(chr(result)).startswith("M"):
        raise argparse.ArgumentTypeError(f"codepoint is not a Unicode combining mark: {value}")
    return result


def lookup_token(value: str, stripped_codepoints: frozenset[int]) -> str:
    decomposed = unicodedata.normalize("NFD", value)
    stripped = "".join(character for character in decomposed if ord(character) not in stripped_codepoints)
    return unicodedata.normalize("NFC", stripped).casefold()


def unicode_word_tokens(text: str) -> Iterator[tuple[int, int, str]]:
    """Yield scalar offsets for letter/number words with marks and connector punctuation."""
    start: int | None = None
    for index, character in enumerate(text):
        category = unicodedata.category(character)
        is_start = category[0] in {"L", "N"}
        is_continue = is_start or category[0] == "M" or category == "Pc"
        if start is None:
            if is_start:
                start = index
        elif not is_continue:
            yield start, index - start, text[start:index]
            start = index if is_start else None
    if start is not None:
        yield start, len(text) - start, text[start:]


def build_tatoeba_index(
    path: pathlib.Path,
    *,
    corpus_language: str,
    stripped_codepoints: frozenset[int],
    maximum_sentences: int,
    maximum_examples_per_token: int,
) -> dict[str, list[CorpusOccurrence]]:
    if maximum_sentences <= 0 or maximum_examples_per_token <= 0:
        raise ValueError("Tatoeba limits must be positive")
    result: dict[str, list[CorpusOccurrence]] = {}
    seen_sentence_digests: set[str] = set()
    accepted_sentences = 0
    with open_bzip2_or_text(path) as source:
        for line_number, line in enumerate(source, start=1):
            if accepted_sentences >= maximum_sentences:
                break
            columns = line.rstrip("\r\n").split("\t", 2)
            if len(columns) != 3:
                raise ValueError(f"Tatoeba line {line_number}: expected ID, language, and sentence")
            sentence_id, language, text = columns
            if language != corpus_language:
                continue
            if not sentence_id or not text or len(text) > MAX_TATOEBA_SENTENCE_CODEPOINTS:
                continue
            sentence_digest = content_digest({"language": language, "text": text})
            if sentence_digest in seen_sentence_digests:
                continue
            seen_sentence_digests.add(sentence_digest)
            tokens = list(unicode_word_tokens(text))
            if not tokens or len(tokens) > MAX_TATOEBA_TOKENS_PER_SENTENCE:
                continue
            accepted_sentences += 1
            seen_keys: set[str] = set()
            for start, length, token in tokens:
                key = lookup_token(token, stripped_codepoints)
                if not key or key in seen_keys:
                    continue
                seen_keys.add(key)
                bucket = result.setdefault(key, [])
                if len(bucket) < maximum_examples_per_token:
                    bucket.append(CorpusOccurrence(sentence_id, text, start, length, token))
    return result


def is_lexical_surface(value: Any) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and value.strip() not in PLACEHOLDER_FORMS
        and any(character.isalnum() for character in value)
    )


def traits(tags: Iterable[str], source_name: str | None = None, roman: str | None = None) -> list[dict[str, str]]:
    result = [{"name": "tag", "value": tag} for tag in tags if isinstance(tag, str) and tag]
    if source_name:
        result.append({"name": "source", "value": source_name})
    if roman:
        result.append({"name": "romanization", "value": roman})
    return result


def text_representation(value: str, language: str | None) -> dict[str, Any]:
    return {"text": {"_0": localized(value, language)}}


def valid_bold_target(example: dict[str, Any], text: str) -> dict[str, Any] | None:
    offsets = example.get("bold_text_offsets")
    if not isinstance(offsets, list) or len(offsets) != 1:
        return None
    pair = offsets[0]
    if (
        not isinstance(pair, list)
        or len(pair) != 2
        or not all(isinstance(value, int) and not isinstance(value, bool) for value in pair)
    ):
        return None
    start, end = pair
    if start < 0 or end <= start or end > len(text):
        return None
    exact = text[start:end]
    if not exact:
        return None
    return {"exactText": exact, "scalarRange": {"location": start, "length": end - start}}


def normalize_entry(
    source: dict[str, Any],
    *,
    language: str,
    definition_language: str | None,
    line_number: int,
    source_id: str,
    source_name: str,
    attribution: str,
    license_name: str,
    wiktionary_base_url: str,
) -> dict[str, Any] | None:
    if source.get("lang_code") != language:
        return None
    word = source.get("word")
    if not is_lexical_surface(word):
        return None

    entry_id = stable_entry_id(source, language, line_number)
    page_url = wiktionary_base_url.rstrip("/") + "/" + urllib.parse.quote(word, safe="")
    entry_provenance = provenance(
        source_id=source_id,
        source_name=source_name,
        record_id=entry_id,
        attribution=attribution,
        license_name=license_name,
        source_url=page_url,
    )
    pos = source.get("pos")
    canonical_traits = []
    if isinstance(pos, str) and pos:
        canonical_traits.append({"name": "partOfSpeech", "value": pos})

    normalized_forms: list[dict[str, Any]] = []
    annotated_canonical_forms: list[tuple[str, str]] = []
    seen_forms: set[tuple[str, tuple[str, ...], str | None, str | None]] = set()
    for source_form in list_value(source.get("forms")):
        if not isinstance(source_form, dict):
            continue
        value = source_form.get("form")
        raw_tags = source_form.get("tags", [])
        form_tags = [tag for tag in raw_tags if isinstance(tag, str)] if isinstance(raw_tags, list) else []
        if not is_lexical_surface(value) or STRUCTURAL_FORM_TAGS.intersection(form_tags):
            continue
        source_kind = source_form.get("source") if isinstance(source_form.get("source"), str) else None
        roman = source_form.get("roman") if isinstance(source_form.get("roman"), str) else None
        key = (value, tuple(sorted(form_tags)), source_kind, roman)
        if key in seen_forms:
            continue
        seen_forms.add(key)
        form_id = stable_id(
            "form",
            {"value": value, "tags": sorted(form_tags), "source": source_kind, "roman": roman},
        )
        kind = "canonical" if "canonical" in form_tags else "romanization" if "romanization" in form_tags else "inflected"
        normalized_forms.append(
            {
                "id": form_id,
                "text": localized(value, None if kind == "romanization" else language),
                "kind": kind,
                "grammaticalFeatures": traits(
                    form_tags,
                    source_kind,
                    roman,
                ),
                "provenance": entry_provenance,
            }
        )
        if "canonical" in form_tags and value != word:
            annotated_canonical_forms.append((form_id, value))

    pronunciations: list[dict[str, Any]] = []
    seen_pronunciations: set[tuple[str, str]] = set()
    for form_id, value in annotated_canonical_forms:
        key = ("orthographic-respelling", value)
        if key in seen_pronunciations:
            continue
        seen_pronunciations.add(key)
        pronunciations.append(
            {
                "id": stable_id("pronunciation", {"scheme": "orthographic-respelling", "value": value}),
                "scheme": "orthographic-respelling",
                "label": "Canonical annotated spelling",
                "representations": [text_representation(value, language)],
                "formIDs": ["canonical"],
                "senseIDs": [],
                "provenance": entry_provenance,
            }
        )
    for sound in list_value(source.get("sounds")):
        if not isinstance(sound, dict):
            continue
        ipa = sound.get("ipa")
        if not isinstance(ipa, str) or not ipa or ("ipa", ipa) in seen_pronunciations:
            continue
        seen_pronunciations.add(("ipa", ipa))
        pronunciations.append(
            {
                "id": stable_id("pronunciation", {"scheme": "ipa", "value": ipa}),
                "scheme": "ipa",
                "label": "IPA",
                "representations": [text_representation(ipa, None)],
                "formIDs": ["canonical"],
                "senseIDs": [],
                "provenance": entry_provenance,
            }
        )

    normalized_senses: list[dict[str, Any]] = []
    seen_senses: set[str] = set()
    for source_sense in list_value(source.get("senses")):
        if not isinstance(source_sense, dict):
            continue
        source_sense_id = source_sense.get("id") if isinstance(source_sense.get("id"), str) else None
        sense_id = stable_id("sense", source_sense_id or source_sense)
        if sense_id in seen_senses:
            continue
        seen_senses.add(sense_id)
        sense_record_id = source_sense_id or f"{entry_id}:{sense_id}"
        sense_provenance = provenance(
            source_id=source_id,
            source_name=source_name,
            record_id=sense_record_id,
            attribution=attribution,
            license_name=license_name,
            source_url=page_url,
        )
        definitions = []
        seen_glosses: set[str] = set()
        for gloss in list_value(source_sense.get("glosses")):
            if isinstance(gloss, str) and gloss:
                definition_id = stable_id("definition", {"sense": sense_id, "text": gloss})
                if definition_id in seen_glosses:
                    continue
                seen_glosses.add(definition_id)
                definitions.append(
                    {
                        "id": definition_id,
                        "text": localized(gloss, definition_language),
                        "provenance": sense_provenance,
                    }
                )
        examples = []
        seen_examples: set[str] = set()
        for source_example in list_value(source_sense.get("examples")):
            if not isinstance(source_example, dict):
                continue
            text = source_example.get("text")
            if not isinstance(text, str) or not text:
                continue
            example_id = stable_id("example", {"sense": sense_id, "source": source_example})
            if example_id in seen_examples:
                continue
            seen_examples.add(example_id)
            example: dict[str, Any] = {
                "id": example_id,
                "text": localized(text, language),
                "provenance": sense_provenance,
            }
            target = valid_bold_target(source_example, text)
            if target is not None:
                example["target"] = target
            examples.append(example)
        labels = []
        for key in ("tags", "raw_tags"):
            value = source_sense.get(key, [])
            if isinstance(value, list):
                labels.extend(tag for tag in value if isinstance(tag, str) and tag)
        normalized_senses.append(
            {
                "id": sense_id,
                "definitions": definitions,
                "examples": examples,
                "labels": list(dict.fromkeys(labels)),
                "provenance": sense_provenance,
            }
        )

    return {
        "id": entry_id,
        "language": language,
        "canonicalForm": {
            "id": "canonical",
            "text": localized(word, language),
            "kind": "lemma",
            "grammaticalFeatures": canonical_traits,
            "provenance": entry_provenance,
        },
        "forms": normalized_forms,
        "pronunciations": pronunciations,
        "senses": normalized_senses,
        "provenance": entry_provenance,
    }


def single_word_lookup_key(value: str, stripped_codepoints: frozenset[int]) -> str | None:
    tokens = list(unicode_word_tokens(value))
    if len(tokens) != 1:
        return None
    start, length, token = tokens[0]
    if value[:start].strip() or value[start + length :].strip():
        return None
    return lookup_token(token, stripped_codepoints)


def enrich_with_tatoeba(
    entry: dict[str, Any],
    *,
    index: dict[str, list[CorpusOccurrence]],
    stripped_codepoints: frozenset[int],
    maximum_examples: int,
    source_id: str,
    source_name: str,
    attribution: str,
    license_name: str,
    sentence_base_url: str,
) -> None:
    form_values = [entry["canonicalForm"]["text"]["value"]]
    form_values.extend(form["text"]["value"] for form in entry["forms"])
    keys = []
    seen_keys: set[str] = set()
    for value in form_values:
        key = single_word_lookup_key(value, stripped_codepoints)
        if key and key not in seen_keys:
            seen_keys.add(key)
            keys.append(key)

    candidates: list[CorpusOccurrence] = []
    seen_sentences: set[str] = set()
    for key in keys:
        for occurrence in index.get(key, []):
            sentence_digest = content_digest(occurrence.text)
            if sentence_digest in seen_sentences:
                continue
            seen_sentences.add(sentence_digest)
            candidates.append(occurrence)
            if len(candidates) >= maximum_examples:
                break
        if len(candidates) >= maximum_examples:
            break
    if not candidates:
        return

    senses = entry["senses"]
    if senses:
        destination_sense = next((sense for sense in senses if sense["definitions"]), senses[0])
    else:
        destination_sense = {
            "id": stable_id("sense", {"entry": entry["id"], "kind": "corpus-examples"}),
            "definitions": [],
            "examples": [],
            "labels": ["corpus-example"],
            "provenance": entry["provenance"],
        }
        senses.append(destination_sense)

    existing_ids = {example["id"] for example in destination_sense["examples"]}
    for occurrence in candidates:
        example_id = stable_id(
            "example",
            {
                "sourceID": source_id,
                "recordID": occurrence.sentence_id,
                "targetStart": occurrence.target_start,
                "targetLength": occurrence.target_length,
            },
        )
        if example_id in existing_ids:
            continue
        existing_ids.add(example_id)
        destination_sense["examples"].append(
            {
                "id": example_id,
                "text": localized(occurrence.text, entry["language"]),
                "target": {
                    "exactText": occurrence.target_text,
                    "scalarRange": {
                        "location": occurrence.target_start,
                        "length": occurrence.target_length,
                    },
                },
                "provenance": provenance(
                    source_id=source_id,
                    source_name=source_name,
                    record_id=occurrence.sentence_id,
                    attribution=attribution,
                    license_name=license_name,
                    source_url=sentence_base_url.rstrip("/") + "/" + urllib.parse.quote(occurrence.sentence_id),
                ),
            }
        )


def open_input(path: pathlib.Path) -> TextIO:
    if path.suffix.lower() == ".gz":
        return gzip.open(path, "rt", encoding="utf-8")
    return path.open("r", encoding="utf-8")


def open_bzip2_or_text(path: pathlib.Path) -> TextIO:
    if path.suffix.lower() == ".bz2":
        return bz2.open(path, "rt", encoding="utf-8")
    return path.open("r", encoding="utf-8")


def normalized_records(
    source: TextIO,
    *,
    tatoeba_index: dict[str, list[CorpusOccurrence]] | None = None,
    stripped_codepoints: frozenset[int] = frozenset(),
    maximum_tatoeba_examples: int = 3,
    tatoeba_source_id: str = "tatoeba",
    tatoeba_source_name: str = "Tatoeba",
    tatoeba_attribution: str = "Tatoeba contributors",
    tatoeba_license: str = "CC BY 2.0 FR; verify per-sentence metadata",
    tatoeba_sentence_base_url: str = "https://tatoeba.org/en/sentences/show",
    **options: Any,
) -> Iterator[dict[str, Any]]:
    seen_entry_ids: set[str] = set()
    for line_number, line in enumerate(source, start=1):
        if not line.strip():
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"line {line_number}: malformed JSON: {error}") from error
        if not isinstance(raw, dict):
            raise ValueError(f"line {line_number}: expected a JSON object")
        normalized = normalize_entry(raw, line_number=line_number, **options)
        if normalized is not None and normalized["id"] not in seen_entry_ids:
            seen_entry_ids.add(normalized["id"])
            if tatoeba_index is not None:
                enrich_with_tatoeba(
                    normalized,
                    index=tatoeba_index,
                    stripped_codepoints=stripped_codepoints,
                    maximum_examples=maximum_tatoeba_examples,
                    source_id=tatoeba_source_id,
                    source_name=tatoeba_source_name,
                    attribution=tatoeba_attribution,
                    license_name=tatoeba_license,
                    sentence_base_url=tatoeba_sentence_base_url,
                )
            yield normalized


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Normalize a local Kaikki JSONL(.gz) export; performs no downloads."
    )
    result.add_argument("--input", required=True, type=pathlib.Path)
    result.add_argument("--output", required=True, type=pathlib.Path)
    result.add_argument("--language", required=True, help="Exact Kaikki lang_code to retain")
    result.add_argument("--definition-language", default="en")
    result.add_argument("--limit", type=int, help="Optional development/test entry limit")
    result.add_argument("--source-id", default="kaikki-wiktionary")
    result.add_argument("--source-name", default="Kaikki.org extraction of Wiktionary")
    result.add_argument(
        "--attribution",
        default="Wiktextract/Kaikki.org extraction of collaboratively authored Wiktionary content",
    )
    result.add_argument("--license", dest="license_name", default="CC BY-SA and GFDL; verify upstream terms")
    result.add_argument("--wiktionary-base-url", default="https://en.wiktionary.org/wiki")
    result.add_argument(
        "--tatoeba",
        type=pathlib.Path,
        help="Optional local Tatoeba per-language sentences TSV or TSV.BZ2",
    )
    result.add_argument(
        "--tatoeba-language",
        help="Exact language column to retain from the Tatoeba file (for example, ukr)",
    )
    result.add_argument("--tatoeba-max-sentences", type=int, default=1_000_000)
    result.add_argument("--tatoeba-max-examples", type=int, default=3)
    result.add_argument(
        "--strip-combining-codepoint",
        type=parse_codepoint,
        action="append",
        default=[],
        metavar="U+XXXX",
        help="Repeatable combining-mark scalar removed only from corpus lookup keys",
    )
    result.add_argument("--tatoeba-source-id", default="tatoeba")
    result.add_argument("--tatoeba-source-name", default="Tatoeba")
    result.add_argument("--tatoeba-attribution", default="Tatoeba contributors")
    result.add_argument(
        "--tatoeba-license",
        default="CC BY 2.0 FR; verify per-sentence metadata",
    )
    result.add_argument(
        "--tatoeba-sentence-base-url",
        default="https://tatoeba.org/en/sentences/show",
    )
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.limit is not None and args.limit <= 0:
        parser().error("--limit must be positive")
    if args.tatoeba_max_sentences <= 0:
        parser().error("--tatoeba-max-sentences must be positive")
    if args.tatoeba_max_examples <= 0:
        parser().error("--tatoeba-max-examples must be positive")
    if not args.input.is_file():
        parser().error(f"input is not a local regular file: {args.input}")
    if args.tatoeba is not None and not args.tatoeba.is_file():
        parser().error(f"Tatoeba input is not a local regular file: {args.tatoeba}")
    if args.tatoeba is not None and not args.tatoeba_language:
        parser().error("--tatoeba-language is required with --tatoeba")
    if args.output.exists():
        parser().error(f"output already exists: {args.output}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    stripped_codepoints = frozenset(args.strip_combining_codepoint)
    tatoeba_index = None
    if args.tatoeba is not None:
        tatoeba_index = build_tatoeba_index(
            args.tatoeba,
            corpus_language=args.tatoeba_language,
            stripped_codepoints=stripped_codepoints,
            maximum_sentences=args.tatoeba_max_sentences,
            maximum_examples_per_token=args.tatoeba_max_examples,
        )
    options = {
        "language": args.language,
        "definition_language": args.definition_language or None,
        "source_id": args.source_id,
        "source_name": args.source_name,
        "attribution": args.attribution,
        "license_name": args.license_name,
        "wiktionary_base_url": args.wiktionary_base_url,
    }
    try:
        with open_input(args.input) as source, args.output.open("x", encoding="utf-8", newline="\n") as output:
            for record in normalized_records(
                source,
                tatoeba_index=tatoeba_index,
                stripped_codepoints=stripped_codepoints,
                maximum_tatoeba_examples=args.tatoeba_max_examples,
                tatoeba_source_id=args.tatoeba_source_id,
                tatoeba_source_name=args.tatoeba_source_name,
                tatoeba_attribution=args.tatoeba_attribution,
                tatoeba_license=args.tatoeba_license,
                tatoeba_sentence_base_url=args.tatoeba_sentence_base_url,
                **options,
            ):
                output.write(json.dumps(record, ensure_ascii=False, separators=(",", ":"), sort_keys=True))
                output.write("\n")
                count += 1
                if args.limit is not None and count >= args.limit:
                    break
    except Exception:
        args.output.unlink(missing_ok=True)
        raise
    print(f"Normalized {count} {args.language} entries to {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
