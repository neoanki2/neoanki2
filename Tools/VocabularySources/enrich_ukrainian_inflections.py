#!/usr/bin/env python3
"""Add verified VESUM/UniMorph word forms to a local Ukrainian definition pack."""

from __future__ import annotations

import argparse
import itertools
import json
import lzma
import pathlib
import sqlite3
import unicodedata

from normalize_stardict_ukrainian import example_key, example_target


def match_key(word: str) -> str:
    return unicodedata.normalize("NFC", word.replace("\u0301", "")).lower().replace("’", "'").replace("ʼ", "'")


def enrich(base_pack: pathlib.Path, morphology: pathlib.Path, output: pathlib.Path,
           supplement: pathlib.Path | None = None) -> tuple[int, int]:
    manifest = json.loads((base_pack / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("languages") != ["uk"] or manifest.get("databaseFile") != "lexicon.sqlite":
        raise ValueError("Expected a local Ukrainian definition pack with a lexicon.sqlite index.")

    database = (base_pack / "lexicon.sqlite").resolve().as_uri() + "?mode=ro"
    with sqlite3.connect(database, uri=True) as connection:
        forms_by_lemma = {match_key(lemma): {} for (lemma,) in connection.execute("SELECT canonical FROM entries")}
        supplemental_rows = []
        if supplement is not None:
            with supplement.open(encoding="utf-8") as source:
                for line in source:
                    entry = json.loads(line)
                    canonical = entry["canonicalForm"]["text"]["value"]
                    key = match_key(canonical)
                    if key not in forms_by_lemma:
                        forms_by_lemma[key] = {}
                        supplemental_rows.append((canonical, line))
        # Some surface forms have several grammatical analyses. Index each spelling once per lemma.
        with lzma.open(morphology, "rt", encoding="utf-8") as source:
            for line_number, line in enumerate(source, 1):
                lemma, separator, remainder = line.partition("\t")
                form, form_separator, _ = remainder.partition("\t")
                if not separator or not form_separator or not form:
                    if line.strip():
                        raise ValueError(f"Invalid UniMorph row {line_number}.")
                    continue
                forms = forms_by_lemma.get(match_key(lemma))
                if forms is not None:
                    forms.setdefault(unicodedata.normalize("NFC", form), line_number)

        entry_count = added_forms = 0
        with output.open("x", encoding="utf-8") as destination:
            base_rows = connection.execute("SELECT canonical, payload FROM entries ORDER BY id")
            for canonical, payload in itertools.chain(base_rows, supplemental_rows):
                entry = json.loads(payload)
                forms = entry["forms"]
                existing = {canonical.lower(), *(form["text"]["value"].lower() for form in forms)}
                for word, line_number in forms_by_lemma[match_key(canonical)].items():
                    spelling = word.lower()
                    if spelling in existing:
                        continue
                    forms.append({
                        "text": {"value": word, "language": "uk"},
                        "kind": "inflected",
                        "grammaticalFeatures": [],
                        "provenance": {"sourceID": "vesum-unimorph", "recordID": f"ukr.xz:{line_number}"},
                    })
                    existing.add(spelling)
                    added_forms += 1
                spellings = {example_key(value) for value in existing}
                for sense in entry.get("senses", []):
                    for example in sense.get("examples", []):
                        if example.get("provenance", {}).get("sourceID") != "stardict-sum11":
                            continue
                        target = example_target(example["text"]["value"], spellings)
                        if target:
                            example["target"] = target
                        else:
                            example.pop("target", None)
                destination.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")
                entry_count += 1
    return entry_count, added_forms


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-pack", required=True, type=pathlib.Path)
    parser.add_argument("--forms", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--supplement", type=pathlib.Path, help="Add documented headwords missing from the base pack (JSONL).")
    args = parser.parse_args()
    entries, forms = enrich(args.base_pack, args.forms, args.output, args.supplement)
    print(f"Wrote {entries:,} entries with {forms:,} additional Ukrainian word forms.")


if __name__ == "__main__":
    main()
