#!/usr/bin/env python3
"""Build an immutable local lookup index for Ukrainian stress and frequency."""

from __future__ import annotations

import argparse
import csv
import hashlib
import lzma
import pathlib
import sqlite3
import sys
import unicodedata


def lookup_key(value: str) -> str:
    decomposed = unicodedata.normalize("NFD", value)
    return unicodedata.normalize(
        "NFC", "".join(character for character in decomposed if character != "\u0301")
    ).casefold()


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build(arguments: argparse.Namespace) -> tuple[int, int]:
    destination = arguments.output
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".part")
    temporary.unlink(missing_ok=True)
    database = sqlite3.connect(temporary)
    try:
        database.executescript(
            """
            PRAGMA page_size = 8192;
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            PRAGMA temp_store = MEMORY;
            PRAGMA auto_vacuum = NONE;
            CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE stress(
              lookup_key TEXT NOT NULL,
              stressed TEXT NOT NULL,
              source_kind INTEGER NOT NULL,
              line_number INTEGER NOT NULL,
              PRIMARY KEY(lookup_key, stressed)
            ) WITHOUT ROWID;
            CREATE TABLE frequency(
              lemma TEXT NOT NULL,
              pos TEXT NOT NULL,
              count INTEGER NOT NULL,
              doc_count INTEGER NOT NULL,
              freq_by_pos REAL NOT NULL,
              freq_in_corpus REAL NOT NULL,
              doc_frequency REAL NOT NULL,
              PRIMARY KEY(lemma, pos)
            ) WITHOUT ROWID;
            """
        )
        stress_count = 0
        batch: list[tuple[str, str, int, int]] = []
        with arguments.stress.open(encoding="utf-8") as source:
            for line_number, line in enumerate(source, start=1):
                stressed = line.rstrip("\r\n")
                if not stressed:
                    continue
                batch.append(
                    (lookup_key(stressed), stressed, 1, line_number)
                )
                if len(batch) >= 10_000:
                    database.executemany(
                        "INSERT OR IGNORE INTO stress VALUES (?, ?, ?, ?)", batch
                    )
                    stress_count += len(batch)
                    batch.clear()
        if batch:
            database.executemany("INSERT OR IGNORE INTO stress VALUES (?, ?, ?, ?)", batch)
            stress_count += len(batch)

        with arguments.heteronyms.open(encoding="utf-8") as source:
            for line_number, line in enumerate(source, start=1):
                columns = line.rstrip("\r\n").split("\t", 1)
                if len(columns) != 2:
                    raise ValueError(f"heteronym line {line_number}: expected two columns")
                headword, variants = columns
                for variant in variants.split(","):
                    database.execute(
                        "INSERT OR IGNORE INTO stress VALUES (?, ?, ?, ?)",
                        (
                            lookup_key(headword),
                            variant,
                            2,
                            line_number,
                        ),
                    )

        frequency_count = 0
        with lzma.open(arguments.frequency, mode="rt", encoding="utf-8", newline="") as source:
            reader = csv.DictReader(source)
            expected = {
                "lemma",
                "pos",
                "count",
                "doc_count",
                "freq_by_pos",
                "freq_in_corpus",
                "doc_frequency",
            }
            if set(reader.fieldnames or []) != expected:
                raise ValueError("unexpected UberText frequency header")
            batch_frequency: list[tuple[object, ...]] = []
            for row in reader:
                batch_frequency.append(
                    (
                        row["lemma"],
                        row["pos"],
                        int(row["count"]),
                        int(row["doc_count"]),
                        float(row["freq_by_pos"]),
                        float(row["freq_in_corpus"]),
                        float(row["doc_frequency"]),
                    )
                )
                if len(batch_frequency) >= 10_000:
                    database.executemany(
                        "INSERT OR REPLACE INTO frequency VALUES (?, ?, ?, ?, ?, ?, ?)",
                        batch_frequency,
                    )
                    frequency_count += len(batch_frequency)
                    batch_frequency.clear()
            if batch_frequency:
                database.executemany(
                    "INSERT OR REPLACE INTO frequency VALUES (?, ?, ?, ?, ?, ?, ?)",
                    batch_frequency,
                )
                frequency_count += len(batch_frequency)

        metadata = {
            "schema_version": "1",
            "stress_sha256": sha256(arguments.stress),
            "heteronyms_sha256": sha256(arguments.heteronyms),
            "frequency_sha256": sha256(arguments.frequency),
            "stress_source": "lang-uk/ukrainian-word-stress-dictionary",
            "heteronyms_source": "lang-uk/ukrainian-heteronyms-dictionary",
            "frequency_source": "UberText 2 lemma frequency",
        }
        database.executemany(
            "INSERT INTO metadata VALUES (?, ?)", sorted(metadata.items())
        )
        database.commit()
        database.execute("PRAGMA optimize")
        if database.execute("PRAGMA integrity_check").fetchone() != ("ok",):
            raise ValueError("local source cache failed SQLite integrity_check")
    finally:
        database.close()
    temporary.replace(destination)
    return stress_count, frequency_count


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stress", required=True, type=pathlib.Path)
    parser.add_argument("--heteronyms", required=True, type=pathlib.Path)
    parser.add_argument("--frequency", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    for path in (arguments.stress, arguments.heteronyms, arguments.frequency):
        if not path.is_file():
            raise SystemExit(f"source not found: {path}")
    try:
        stress_count, frequency_count = build(arguments)
    except (OSError, ValueError, sqlite3.Error) as error:
        raise SystemExit(f"error: {error}") from error
    print(
        f"Indexed {stress_count} stress rows and {frequency_count} frequency rows "
        f"to {arguments.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
