import gzip
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
from normalize_learning_dictionaries import jmdict_entries, wordnet_entries


class LearningDictionaryTests(unittest.TestCase):
    def convert(self, xml, parse):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "dictionary.xml.gz"
            with gzip.open(source, "wt", encoding="utf-8") as output:
                output.write(xml)
            return list(parse(source))

    def test_wordnet_links_each_example_to_its_english_sense_and_form(self):
        entry, = self.convert("""
            <LexicalResource><Lexicon><LexicalEntry id="run-v">
              <Lemma writtenForm="run" partOfSpeech="v"/><Form writtenForm="ran"/>
              <Sense id="run-1" synset="speed"/>
            </LexicalEntry><Synset id="speed">
              <Definition>Travel on foot at speed.</Definition>
              <Example>🏃 She ran home.</Example><Example>He sprinted away.</Example>
              <Example>They ran and ran again.</Example>
            </Synset></Lexicon></LexicalResource>
        """, wordnet_entries)
        sense, = entry["senses"]
        example, = sense["examples"]
        self.assertEqual(sense["definitions"][0]["text"]["language"], "en")
        self.assertEqual(example["target"], {"exactText": "ran", "scalarRange": {"location": 6, "length": 3}})
        self.assertEqual(example["provenance"]["recordID"], "speed")

    def test_jmdict_retains_reading_restrictions_and_japanese_example_attribution(self):
        entries = self.convert("""
            <JMdict><entry><ent_seq>1</ent_seq>
              <k_ele><keb>開く</keb></k_ele>
              <r_ele><reb>あく</reb></r_ele><r_ele><reb>ひらく</reb></r_ele>
              <sense><stagr>あく</stagr><gloss>to open</gloss>
                <example><ex_srce exsrc_type="tat">123</ex_srce><ex_text>開いた</ex_text>
                  <ex_sent xml:lang="jpn">ドアが開いた。</ex_sent>
                  <ex_sent xml:lang="eng">The door opened.</ex_sent>
                </example>
              </sense>
              <sense><stagr>ひらく</stagr><gloss>to hold</gloss><gloss xml:lang="fre">tenir</gloss></sense>
            </entry></JMdict>
        """, lambda path: jmdict_entries(path, {"123": "test-author"}, {"123"}))
        opening = next(entry for entry in entries if entry["canonicalForm"]["text"]["value"] == "あく")
        sense, = opening["senses"]
        example, = sense["examples"]
        self.assertEqual(sense["definitions"][0]["text"], {"value": "to open", "language": "en"})
        self.assertEqual(example["text"]["language"], "ja")
        self.assertEqual(example["target"]["exactText"], "開いた")
        self.assertEqual(example["provenance"]["attribution"], "test-author")
        self.assertEqual(example["provenance"]["license"], "CC0 1.0")
        self.assertIn("開いた", [form["text"]["value"] for form in opening["forms"]])
