import bz2
import gzip
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "normalize_kaikki.py"
SPEC = importlib.util.spec_from_file_location("normalize_kaikki", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class KaikkiNormalizerTests(unittest.TestCase):
    def test_preserves_generic_lexical_content_and_scalar_target(self):
        source = {
            "word": "cafe",
            "lang_code": "xy",
            "pos": "noun",
            "forms": [
                {"form": "cafe\u0301", "tags": ["canonical"]},
                {"form": "cafes", "tags": ["plural"], "source": "declension"},
                {"form": "template-name", "tags": ["inflection-template"]},
            ],
            "sounds": [{"ipa": "/kafe/"}],
            "senses": [
                {
                    "id": "source-sense",
                    "glosses": ["a test gloss"],
                    "tags": ["figurative"],
                    "examples": [
                        {
                            "text": "🙂 cafe\u0301 here",
                            "bold_text_offsets": [[2, 7]],
                            "type": "example",
                        }
                    ],
                }
            ],
        }
        result = MODULE.normalize_entry(
            source,
            language="xy",
            definition_language="en",
            line_number=1,
            source_id="source",
            source_name="Source",
            attribution="Attribution",
            license_name="License",
            wiktionary_base_url="https://example.invalid/wiki",
        )

        self.assertEqual(result["canonicalForm"]["text"]["language"], "xy")
        self.assertEqual(result["canonicalForm"]["provenance"]["sourceID"], "source")
        schemes = [item["scheme"] for item in result["pronunciations"]]
        self.assertEqual(schemes, ["orthographic-respelling", "ipa"])
        self.assertTrue(all(item["provenance"]["sourceID"] == "source" for item in result["pronunciations"]))
        self.assertNotIn("template-name", [form["text"]["value"] for form in result["forms"]])
        self.assertTrue(all(form["provenance"]["sourceID"] == "source" for form in result["forms"]))
        example = result["senses"][0]["examples"][0]
        self.assertEqual(example["target"]["exactText"], "cafe\u0301")
        self.assertEqual(example["target"]["scalarRange"], {"location": 2, "length": 5})
        self.assertEqual(result["provenance"]["license"], "License")
        self.assertEqual(result["senses"][0]["definitions"][0]["provenance"]["sourceID"], "source")

    def test_null_source_collections_are_treated_as_empty(self):
        result = MODULE.normalize_entry(
            {"word": "safe", "lang_code": "xy", "forms": None, "sounds": None, "senses": None},
            language="xy",
            definition_language="en",
            line_number=1,
            source_id="source",
            source_name="Source",
            attribution="Attribution",
            license_name="License",
            wiktionary_base_url="https://example.invalid/wiki",
        )
        self.assertEqual(result["forms"], [])
        self.assertEqual(result["pronunciations"], [])
        self.assertEqual(result["senses"], [])

    def test_ambiguous_bold_offsets_do_not_guess_a_target(self):
        example = {"bold_text_offsets": [[0, 3], [4, 7]]}
        self.assertIsNone(MODULE.valid_bold_target(example, "one one"))

    def test_main_filters_language_and_reads_gzip_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.jsonl.gz"
            output = root / "output.jsonl"
            records = [
                {"word": "keep", "lang_code": "aa", "senses": []},
                {"word": "drop", "lang_code": "bb", "senses": []},
            ]
            with gzip.open(source, "wt", encoding="utf-8") as handle:
                for record in records:
                    handle.write(json.dumps(record) + "\n")

            code = MODULE.main(
                ["--input", str(source), "--output", str(output), "--language", "aa"]
            )
            self.assertEqual(code, 0)
            normalized = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual([entry["canonicalForm"]["text"]["value"] for entry in normalized], ["keep"])

    def test_ids_ignore_physical_line_and_semantic_duplicates_are_deduped(self):
        source = {"word": "stable", "lang_code": "xy", "senses": [{"glosses": ["same"]}]}
        self.assertEqual(
            MODULE.stable_entry_id(source, "xy", line_number=1),
            MODULE.stable_entry_id(source, "xy", line_number=999),
        )
        lines = io.StringIO(
            json.dumps(source, ensure_ascii=False, separators=(",", ":"))
            + "\n"
            + json.dumps({"senses": source["senses"], "lang_code": "xy", "word": "stable"})
            + "\n"
        )
        records = list(
            MODULE.normalized_records(
                lines,
                language="xy",
                definition_language="en",
                source_id="source",
                source_name="Source",
                attribution="Attribution",
                license_name="License",
                wiktionary_base_url="https://example.invalid/wiki",
            )
        )
        self.assertEqual(len(records), 1)

    def test_filters_placeholder_forms_and_leaves_romanization_language_unspecified(self):
        result = MODULE.normalize_entry(
            {
                "word": "word",
                "lang_code": "xy",
                "forms": [
                    {"form": "-", "tags": ["inflected"]},
                    {"form": "wurd", "tags": ["romanization"]},
                ],
            },
            language="xy",
            definition_language="en",
            line_number=1,
            source_id="source",
            source_name="Source",
            attribution="Attribution",
            license_name="License",
            wiktionary_base_url="https://example.invalid/wiki",
        )
        self.assertEqual([form["text"]["value"] for form in result["forms"]], ["wurd"])
        self.assertNotIn("language", result["forms"][0]["text"])

    def test_only_combining_mark_codepoints_can_be_stripped(self):
        self.assertEqual(MODULE.parse_codepoint("U+0301"), 0x0301)
        with self.assertRaises(Exception):
            MODULE.parse_codepoint("U+0061")

    def test_tatoeba_bzip2_enrichment_is_bounded_generic_and_scalar_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source.jsonl.gz"
            corpus = root / "sentences.tsv.bz2"
            output = root / "output.jsonl"
            entry = {
                "word": "cafe",
                "lang_code": "xy",
                "senses": [{"id": "drink", "glosses": ["a cafe"]}],
            }
            with gzip.open(source, "wt", encoding="utf-8") as handle:
                handle.write(json.dumps(entry) + "\n")
            with bz2.open(corpus, "wt", encoding="utf-8") as handle:
                handle.write("10\txyz\t🙂 cafe\u0301 works.\n")
                handle.write("11\txyz\t🙂 cafe\u0301 works.\n")  # exact duplicate content
                handle.write("12\txyz\tAnother cafe\u0301 works.\n")
                handle.write("13\tother\tcafe should be filtered.\n")

            code = MODULE.main(
                [
                    "--input",
                    str(source),
                    "--output",
                    str(output),
                    "--language",
                    "xy",
                    "--tatoeba",
                    str(corpus),
                    "--tatoeba-language",
                    "xyz",
                    "--tatoeba-max-examples",
                    "1",
                    "--strip-combining-codepoint",
                    "U+0301",
                ]
            )
            self.assertEqual(code, 0)
            normalized = json.loads(output.read_text(encoding="utf-8").strip())
            examples = normalized["senses"][0]["examples"]
            self.assertEqual(len(examples), 1)
            example = examples[0]
            self.assertEqual(example["text"], {"value": "🙂 cafe\u0301 works.", "language": "xy"})
            self.assertEqual(example["target"]["exactText"], "cafe\u0301")
            self.assertEqual(example["target"]["scalarRange"], {"location": 2, "length": 5})
            self.assertEqual(example["provenance"]["sourceID"], "tatoeba")
            self.assertEqual(example["provenance"]["recordID"], "10")
            self.assertTrue(example["provenance"]["sourceURL"].endswith("/10"))


if __name__ == "__main__":
    unittest.main()
