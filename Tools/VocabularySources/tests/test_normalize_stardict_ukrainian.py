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
        self.assertEqual(entry["pronunciations"][0]["representations"][0]["text"]["_0"]["value"], "АБАЖУ́Р")
        self.assertEqual(entry["pronunciations"][0]["formIDs"], ["canonical"])
        self.assertEqual(
            entry["senses"][0]["definitions"][0]["text"]["value"],
            "Дашок для захисту очей від світла.",
        )
        self.assertEqual(entry["senses"][0]["examples"][0]["text"]["value"], "Під абажуром блимала лампа.")

    def test_sum_examples_follow_their_subsense_and_homonym(self) -> None:
        article = (
            '<div style="margin-left:1em"><font color="maroon"><b>ЧЕРЕДА́¹</b></font>, и, <i>ж.</i> Гурт тварин.</div>'
            '<div style="margin-left:3em"><i>Там паслася череда.</i><font color="dodgerblue">(Автор, 12)</font>;</div>'
            '<div style="margin-left:1em">// Ряд предметів. <span class="ex"><i>Виднілася череда хат.</i></span></div>'
            '<div style="margin-left:1em"><font color="maroon"><b>ЧЕРЕДА́²</b></font>, и, <i>ж.</i> Лікарська рослина.</div>'
            '<div style="margin-left:2em"><i>Череда, а за нею інша череда, росли тут.</i></div>'
        )
        entry = MODULE.normalize_sum_entry("череда", article, 3, 10, "a" * 64)
        self.assertEqual(len(entry["senses"]), 3)
        first, second, third = (sense["examples"][0] for sense in entry["senses"])
        self.assertEqual(first["provenance"]["attribution"], "(Автор, 12)")
        self.assertEqual(first["target"]["exactText"], "череда")
        self.assertEqual(second["text"]["value"], "Виднілася череда хат.")
        self.assertNotIn("target", third)

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

    def test_sum_adjective_endings_are_metadata_and_keep_numbered_senses(self) -> None:
        article = (
            '<div style="margin-left:1em"><font color="maroon"><b>КІ́ПТЯ́ВИЙ</b></font>, а, е.</div>'
            '<div style="margin-left:1em">1. Який коптить.</div>'
            '<div style="margin-left:3em"><i>Кіптявий каганець.</i></div>'
            '<div style="margin-left:1em">2. Покритий кіптем; закопчений.</div>'
        )
        entry = MODULE.normalize_sum_entry("кіптявий", article, 7, 11, "c" * 64)
        self.assertEqual(entry["canonicalForm"]["grammaticalFeatures"],
                         [{"name": "dictionaryHeader", "value": "КІ́ПТЯ́ВИЙ, а, е."}])
        meanings = [definition["text"]["value"] for sense in entry["senses"] for definition in sense["definitions"]]
        self.assertEqual(meanings, ["Який коптить.", "Покритий кіптем; закопчений."])

    def test_sum_inline_meaning_keeps_an_embedded_italic_reference(self) -> None:
        article = ('<div style="margin-left:1em"><font color="maroon"><b>ПАРОМІ́Р</b></font>, а, <i>ч.</i> '
                   'Прилад для вимірювання витрати пари (<i>див.</i> <b>па́ра²</b> 1).</div>')
        entry = MODULE.normalize_sum_entry("паромір", article, 7, 11, "c" * 64)
        self.assertEqual(entry["senses"][0]["definitions"][0]["text"]["value"],
                         "Прилад для вимірювання витрати пари (див. па́ра² 1).")

    def test_sum_missing_definition_keeps_the_headword_without_a_sense(self) -> None:
        article = '<div style="margin-left:1em"><font color="maroon"><b>ЛІПОТА́</b></font>, <i>и́, ж., заст</i>.</div>'
        entry = MODULE.normalize_sum_entry("ліпота", article, 7, 11, "c" * 64)
        self.assertEqual(entry["canonicalForm"]["text"]["value"], "ліпота")
        self.assertEqual(entry["senses"], [])

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
