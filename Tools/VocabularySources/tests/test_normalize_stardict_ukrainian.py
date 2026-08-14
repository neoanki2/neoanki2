from __future__ import annotations

import importlib.util
import pathlib
import struct
import tempfile
import unittest
import zipfile


MODULE_PATH = pathlib.Path(__file__).parents[1] / "normalize_stardict_ukrainian.py"
SPEC = importlib.util.spec_from_file_location("normalize_stardict_ukrainian", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def star_index(records: list[tuple[str, str]]) -> tuple[bytes, bytes]:
    index = bytearray()
    dictionary = bytearray()
    for word, article in records:
        encoded = article.encode("utf-8")
        index.extend(word.encode("utf-8"))
        index.append(0)
        index.extend(struct.pack(">II", len(dictionary), len(encoded)))
        dictionary.extend(encoded)
    return bytes(index), bytes(dictionary)


class NormalizeStarDictTests(unittest.TestCase):
    def test_sum_entry_preserves_head_definition_and_stress(self) -> None:
        article = (
            '<div style="margin-left:1em"><font><b>АБАЖУ́Р</b></font>, а, '
            '<i>ч.</i> Дашок для захисту очей від світла.</div>'
            '<div style="margin-left:3em"><i>Під абажуром блимала лампа.</i></div>'
        )
        entry = MODULE.normalize_sum_entry("абажур", article, 3, 10, "a" * 64)
        self.assertIsNotNone(entry)
        assert entry is not None
        self.assertEqual(entry["canonicalForm"]["text"]["value"], "абажур")
        self.assertEqual(
            entry["canonicalForm"]["grammaticalFeatures"],
            [{"name": "dictionaryHeader", "value": "АБАЖУ́Р, а, ч."}],
        )
        self.assertEqual(entry["forms"][0]["text"]["value"], "АБАЖУ́Р")
        self.assertEqual(
            entry["senses"][0]["definitions"][0]["text"]["value"],
            "Дашок для захисту очей від світла.",
        )
        self.assertEqual(entry["senses"][0]["examples"], [])

    def test_ruuk_entry_indexes_exact_ukrainian_translation(self) -> None:
        article = (
            '<div style="margin-left:1em"><i class="p">сущ.</i></div>'
            '<div style="margin-left:1em">ковдра <i class="p">імен.</i></div>'
        )
        entry = MODULE.normalize_ruuk_entry(
            "одеяло", article, 5, 10, "b" * 64, {"ковдра"}
        )
        self.assertIsNotNone(entry)
        assert entry is not None
        self.assertEqual(entry["language"], "ru")
        self.assertEqual(entry["canonicalForm"]["text"]["value"], "одеяло")
        self.assertEqual(entry["forms"][0]["text"], {"value": "ковдра", "language": "uk"})

    def test_sum_header_only_uses_next_dictionary_paragraph(self) -> None:
        article = (
            '<div style="margin-left:1em"><font><b>ЗА́МОК</b></font>, мка, '
            '<i>ч.</i></div>'
            '<div style="margin-left:1em">Укріплене житло феодала доби середньовіччя.</div>'
        )
        entry = MODULE.normalize_sum_entry("замок", article, 7, 11, "c" * 64)
        self.assertIsNotNone(entry)
        assert entry is not None
        self.assertEqual(
            entry["senses"][0]["definitions"][0]["text"]["value"],
            "Укріплене житло феодала доби середньовіччя.",
        )

    def test_archive_member_resolution_and_normalization(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            archive_path = root / "sources.zip"
            output_path = root / "sum.jsonl"
            sum_index, sum_dict = star_index(
                [("слово", '<div style="margin-left:1em"><b>СЛО́ВО</b>, <i>с.</i> Одиниця мови.</div>')]
            )
            ru_index, ru_dict = star_index(
                [("слово", '<div style="margin-left:1em">слово</div>')]
            )
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("ukr-ukr_SUM-11_or_1/sum.idx", sum_index)
                archive.writestr("ukr-ukr_SUM-11_or_1/sum.dict", sum_dict)
                archive.writestr("ru-uk_velykyi_ros-uk_slovnyk/dictionary.idx", ru_index)
                archive.writestr("ru-uk_velykyi_ros-uk_slovnyk/dictionary.dict", ru_dict)
            self.assertEqual(MODULE.normalize(archive_path, output_path, "sum11"), 1)
            self.assertEqual(len(output_path.read_text(encoding="utf-8").splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
