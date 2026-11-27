#!/usr/bin/env python3
"""Convert local Open English WordNet or JMdict example XML into NeoAnki entries."""

from __future__ import annotations

import argparse
import bz2
import gzip
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path


WORDNET = {
    "sourceID": "open-english-wordnet",
    "sourceName": "Open English WordNet",
    "attribution": "Open English WordNet Community, derived from Princeton WordNet",
    "license": "CC BY 4.0",
    "sourceURL": "https://en-word.net/downloads",
}
JMDICT = {
    "sourceID": "edrdg-jmdict",
    "sourceName": "JMdict",
    "attribution": "Electronic Dictionary Research and Development Group (EDRDG)",
    "license": "CC BY-SA 4.0",
    "sourceURL": "https://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project",
}
XML_LANGUAGE = "{http://www.w3.org/XML/1998/namespace}lang"
PARTS_OF_SPEECH = dict(n="noun", v="verb", a="adjective", s="adjective", r="adverb")


def elements(path, tags, parent_tag):
    """Stream whole records while releasing each record from its shared parent."""
    with gzip.open(path, "rb") as source:
        parent = None
        for event, element in ET.iterparse(source, events=("start", "end")):
            if event == "start" and element.tag == parent_tag:
                parent = element
            if event == "end" and element.tag in tags:
                yield element
                parent.remove(element)


def values(element, path):
    return [node.text.strip() for node in element.findall(path) if node.text and node.text.strip()]


def localized(text, language):
    return {"value": text, "language": language}


def form(text, language, kind, part_of_speech=None):
    result = {"text": localized(text, language), "kind": kind, "grammaticalFeatures": []}
    if part_of_speech:
        result["grammaticalFeatures"] = [{"name": "partOfSpeech", "value": part_of_speech}]
    return result


def unique_target(sentence, spellings, language):
    clean = [spelling for spelling in dict.fromkeys(spellings) if spelling]
    if not clean:
        return None
    pattern = "|".join(map(re.escape, sorted(clean, key=len, reverse=True)))
    if language == "en":
        pattern = rf"(?<!\w)(?:{pattern})(?!\w)"
    matches = list(re.finditer(pattern, sentence, re.IGNORECASE if language == "en" else 0))
    if len(matches) != 1:
        return None
    target = matches[0]
    if not any(character.isalpha() for character in sentence[:target.start()] + sentence[target.end():]):
        return None
    return {"exactText": target[0], "scalarRange": {"location": target.start(), "length": len(target[0])}}


def wordnet_entries(path):
    synsets = {}
    for synset in elements(path, {"LexicalEntry", "Synset"}, "Lexicon"):
        if synset.tag == "Synset":
            synsets[synset.attrib["id"]] = (values(synset, "Definition"), values(synset, "Example"))
    for entry in elements(path, {"LexicalEntry", "Synset"}, "Lexicon"):
        if entry.tag != "LexicalEntry":
            continue
        lemma = entry.find("Lemma")
        headword = lemma.attrib["writtenForm"]
        entry_id = entry.attrib["id"]
        shapes = list(dict.fromkeys(node.attrib["writtenForm"] for node in entry.findall("Form")))
        senses = []
        for sense in entry.findall("Sense"):
            synset_id = sense.attrib["synset"]
            definitions, examples = synsets[synset_id]
            if not definitions:
                continue
            provenance = {**WORDNET, "recordID": synset_id, "sourceURL": f"https://en-word.net/id/{synset_id}"}
            usage = []
            for sentence in sorted(dict.fromkeys(examples), key=lambda text: len(text.split()) < 5):
                if target := unique_target(sentence, [headword, *shapes], "en"):
                    usage.append({"text": localized(sentence, "en"), "target": target, "provenance": provenance})
            senses.append({"id": sense.attrib["id"], "definitions": [
                {"text": localized(definition, "en"), "provenance": provenance} for definition in definitions
            ], "examples": usage, "labels": []})
        if not senses:
            continue
        pronunciation = []
        for node in lemma.findall("Pronunciation"):
            if node.text and node.text.strip():
                pronunciation.append({
                    "scheme": "ipa",
                    "label": node.attrib.get("variety", "IPA"),
                    "representations": [{"text": {"_0": {"value": node.text.strip()}}}],
                })
        yield {
            "id": entry_id,
            "language": "en",
            "canonicalForm": form(headword, "en", "lemma", PARTS_OF_SPEECH.get(lemma.attrib["partOfSpeech"])),
            "forms": [form(shape, "en", "inflected") for shape in shapes if shape != headword],
            "senses": senses,
            "pronunciations": pronunciation,
            "provenance": {**WORDNET, "recordID": entry_id},
        }


def tatoeba_metadata(details, cc0):
    with bz2.open(details, "rt", encoding="utf-8") as source:
        owners = {}
        for line in source:
            sentence_id, _, _, username, *_ = line.rstrip("\n").split("\t")
            if username and username != r"\N":
                owners[sentence_id] = username
    with bz2.open(cc0, "rt", encoding="utf-8") as source:
        open_ids = {line.split("\t", 1)[0] for line in source}
    return owners, open_ids


def japanese_example(example, owners, open_ids):
    sentence = example.findtext(f"ex_sent[@{XML_LANGUAGE}='jpn']", "").strip()
    if not sentence:
        return None
    source_id = example.findtext("ex_srce[@exsrc_type='tat']", "").strip()
    owner = owners.get(source_id)
    provenance = {
        "sourceID": "tatoeba",
        "sourceName": "Tatoeba via JMdict",
        "license": "CC0 1.0" if source_id in open_ids else "CC BY 2.0 FR (Tatoeba default)",
        "sourceURL": f"https://tatoeba.org/en/sentences/show/{source_id}" if source_id.isdecimal()
            else "https://tatoeba.org/en/downloads",
    }
    if source_id:
        provenance["recordID"] = source_id
    if owner:
        provenance["attribution"] = owner
    result = {"text": localized(sentence, "ja"), "provenance": provenance}
    if target := unique_target(sentence, values(example, "ex_text"), "ja"):
        result["target"] = target
    return result


def jmdict_entries(path, owners, open_ids):
    for entry in elements(path, {"entry"}, "JMdict"):
        record_id = entry.findtext("ent_seq")
        provenance = {**JMDICT, "recordID": record_id}
        written = values(entry, "k_ele/keb")
        readings = values(entry, "r_ele/reb")
        pairs = set()
        for reading in entry.findall("r_ele"):
            kana = reading.findtext("reb")
            writings = (None,) if reading.find("re_nokanji") is not None else values(reading, "re_restr") or written or (None,)
            pairs.update((kanji, kana) for kanji in writings)

        senses = []
        membership = {spelling: [] for spelling in dict.fromkeys([*written, *readings])}
        for index, sense in enumerate(entry.findall("sense"), start=1):
            glosses = list(dict.fromkeys(
                node.text.strip() for node in sense.findall("gloss")
                if node.attrib.get(XML_LANGUAGE, "eng") == "eng" and node.text and node.text.strip()
            ))
            if not glosses:
                continue
            kanji_limits, kana_limits = set(values(sense, "stagk")), set(values(sense, "stagr"))
            members = {
                spelling for kanji, kana in pairs
                if (not kanji_limits or kanji in kanji_limits) and (not kana_limits or kana in kana_limits)
                for spelling in (kanji, kana) if spelling in membership
            }
            examples = [result for example in sense.findall("example")
                        if (result := japanese_example(example, owners, open_ids)) is not None]
            meaning = ", ".join(glosses)
            senses.append({
                "id": f"{record_id}:{index}",
                "definitions": [{"text": localized(meaning, "en"), "provenance": provenance}],
                "examples": examples,
                "labels": values(sense, "pos") + values(sense, "misc"),
            })
            for spelling in members:
                membership[spelling].append(len(senses) - 1)

        by_sense = {}
        for spelling, indexes in membership.items():
            if indexes:
                by_sense.setdefault(tuple(indexes), []).append(spelling)
        for index, (indexes, spellings) in enumerate(by_sense.items()):
            headword, *variants = spellings
            group_senses = [senses[sense_index] for sense_index in indexes]
            forms = [form(value, "ja", "reading" if value in readings else "variant") for value in variants]
            attested = dict.fromkeys(example["target"]["exactText"] for sense in group_senses
                                    for example in sense["examples"] if "target" in example)
            forms.extend(form(value, "ja", "inflected") for value in attested if value not in membership)
            yield {
                "id": f"jmdict:{record_id}:{index}",
                "language": "ja",
                "canonicalForm": form(headword, "ja", "lemma"),
                "forms": forms,
                "senses": group_senses,
                "pronunciations": [],
                "provenance": provenance,
            }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dictionary", choices=["wordnet", "jmdict"])
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tatoeba-details", type=Path)
    parser.add_argument("--tatoeba-cc0", type=Path)
    args = parser.parse_args()
    if args.dictionary == "jmdict" and (not args.tatoeba_details or not args.tatoeba_cc0):
        parser.error("JMdict requires both Japanese Tatoeba attribution exports.")
    entries = (wordnet_entries(args.input) if args.dictionary == "wordnet"
               else jmdict_entries(args.input, *tatoeba_metadata(args.tatoeba_details, args.tatoeba_cc0)))
    with args.output.open("x", encoding="utf-8") as output:
        for entry in entries:
            output.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
