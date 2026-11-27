import json
import lzma
import pathlib
import sqlite3
import sys
import tempfile
import unittest


SOURCE_ROOT = pathlib.Path(__file__).parents[1]
sys.path.insert(0, str(SOURCE_ROOT))
import enrich_ukrainian_inflections as MODULE


class UkrainianInflectionsTests(unittest.TestCase):
    def test_adds_attested_forms_to_existing_and_supplemental_headwords(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "manifest.json").write_text(json.dumps({"languages": ["uk"], "databaseFile": "lexicon.sqlite"}))
            entry = {"forms": [{"text": {"value": "ПА́ГОРОК"}}], "senses": [{"definitions": ["Невелике узвишшя."]}]}
            with sqlite3.connect(root / "lexicon.sqlite") as connection:
                connection.execute("CREATE TABLE entries (id TEXT, canonical TEXT, payload BLOB)")
                connection.execute("INSERT INTO entries VALUES (?, ?, ?)", ("hill", "пагорок", json.dumps(entry)))
            morphology = root / "ukr.xz"
            with lzma.open(morphology, "wt", encoding="utf-8") as source:
                source.write("па́горок\tпагорків\tN;GEN;PL\tINAN;MASC\n"
                             "пагорок\tпагорків\tN;GEN;PL\n"
                             "пагорок\tпагорок\tN;NOM;SG\n"
                             "пагорб\tпагорбів\tN;GEN;PL\n")

            output = root / "entries.jsonl"
            self.assertEqual(MODULE.enrich(root, morphology, output), (1, 1))
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(result["senses"], entry["senses"])
            self.assertEqual([form["text"]["value"] for form in result["forms"]], ["ПА́ГОРОК", "пагорків"])
            self.assertEqual(result["forms"][1]["provenance"]["recordID"], "ukr.xz:1")

            supplement = root / "supplement.jsonl"
            missing = json.loads((SOURCE_ROOT / "ukrainian-supplement.jsonl").read_text(encoding="utf-8"))
            matching = {"canonicalForm": {"text": {"value": "Па́горок"}}}
            supplement.write_text("\n".join(json.dumps(row) for row in [missing, matching]), encoding="utf-8")
            with lzma.open(morphology, "at", encoding="utf-8") as source:
                source.write("млость\tмлостю\tN;INS;SG\nмлость\tмлость\tN;NOM;SG\n")

            output = root / "supplemented.jsonl"
            self.assertEqual(MODULE.enrich(root, morphology, output, supplement), (2, 2))
            original, added = map(json.loads, output.read_text(encoding="utf-8").splitlines())
            self.assertEqual(original, result)
            self.assertEqual(added["canonicalForm"], missing["canonicalForm"])
            self.assertEqual(added["senses"], missing["senses"])
            self.assertEqual([form["text"]["value"] for form in added["forms"]], ["млостю"])
