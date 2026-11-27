---
title: Offline vocabulary packs
description: Normalize local lexical datasets, compile .neovocab packs, validate them, and search without network access.
audience: developer
parent: Developer Guide
---

# Offline vocabulary packs

NeoAnki vocabulary lookup is local-only. The user imports a `.neovocab`
directory once; the application validates and copies it into library-managed
storage, then queries its read-only SQLite index. It has no vocabulary download
client. Source acquisition is an explicit deck-author or developer operation
performed before import.

Authorized local automation clients use the same managed library through the
[Vocabulary API]({{ '/VOCABULARY_API/' | relative_url }}). The HTTP surface preserves the offline
boundary: clients upload declared bytes into private staging and cannot submit
a filesystem path or remote URL.

## Pipeline

```text
downloaded source file -> source-specific normalizer -> LexicalEntry JSONL
                       -> neoanki-vocab compile      -> .neovocab directory
                       -> NeoAnki pack import        -> managed offline pack
                       -> deck-scoped local lookup  -> items in an existing deck
```

The normalized model remains language-neutral: lexical entries contain a BCP-47
language, canonical and inflected forms, open grammatical traits, pronunciation
representations and schemes, senses, definitions, examples, scalar target ranges,
and structured provenance. Pronunciations may declare the form and sense IDs to
which they apply, preventing conflicting heteronym cards.

## `neoanki-vocab` CLI

Build the executable with SwiftPM or invoke it through `swift run`:

```sh
swift run neoanki-vocab --help
```

Compile normalized JSONL:

```sh
swift run neoanki-vocab compile \
  --input .local/vocab-packs/entries.jsonl \
  --output .local/vocab-packs/Example.neovocab \
  --id example.lexicon \
  --title "Example Lexicon" \
  --language en \
  --capability lexicon \
  --capability pronunciation \
  --source-id example-source \
  --source-name "Example Source" \
  --license "Review source terms"
```

Validate and search:

```sh
swift run neoanki-vocab validate \
  --pack .local/vocab-packs/Example.neovocab

swift run neoanki-vocab search \
  --pack .local/vocab-packs/Example.neovocab \
  --query example \
  --language en \
  --exact
```

`compile`, `validate`, and `search` reject URL-shaped input paths. None performs
network access. Compilation refuses to overwrite an existing pack.

## Install a local pack from the terminal

```sh
swift run neoanki-vocab install --pack /path/to/Pack.neovocab \
  --root "$HOME/Library/Application Support/neoanki2/Vocabulary Packs"
```

The command validates and copies the pack into the local Mac library. A pack
with the same identifier must be managed through the existing Vocabulary Packs
tools before importing a replacement.

## Kaikki/Wiktextract adapter

`Tools/VocabularySources/normalize_kaikki.py` reads a local Kaikki JSONL or
JSONL.GZ file and writes normalized `LexicalEntry` JSONL. The adapter understands
Kaikki's schema but contains no branches for a particular natural language.

```sh
python3 Tools/VocabularySources/normalize_kaikki.py \
  --input /path/to/kaikki-language.jsonl.gz \
  --output .local/vocab-packs/kaikki-language.jsonl \
  --language uk \
  --definition-language en \
  --tatoeba /path/to/local-language-sentences.tsv.bz2 \
  --tatoeba-language ukr \
  --tatoeba-max-examples 3 \
  --strip-combining-codepoint U+0301
```

It preserves:

- canonical, inflected, and romanized forms plus grammatical tags;
- IPA as the generic `ipa` pronunciation scheme;
- an annotated canonical spelling distinct from the lookup lemma as the generic
  `orthographic-respelling` scheme;
- senses and individual gloss definitions;
- examples, with an explicit Unicode-scalar target only when exactly one valid
  `bold_text_offsets` range exists; and
- Kaikki/Wiktextract/Wiktionary source identity, attribution, license text, record
  identity, and source page URL.

The optional Tatoeba input is also strictly local. The adapter builds a bounded
in-memory index by generic Unicode letter/number word tokens, deduplicates exact
sentence content, and adds at most `--tatoeba-max-examples` corpus examples to an
entry. Each example retains the sentence's exact surface token, Unicode-scalar
range, Tatoeba sentence ID, attribution, license, and metadata URL. Repeat
`--strip-combining-codepoint` to remove specified marks from lookup keys only;
the original sentence and cloze target are never rewritten. Language selection
is explicit through `--tatoeba-language`; there is no language-specific adapter
branch. Romanizations intentionally have no BCP-47 language tag, and placeholder
forms such as `-` are discarded.

Remote audio URLs are intentionally not copied into normalized entries. Audio must
already be a local pack asset in a NeoAnki-supported format.

## Package layout

```text
Example.neovocab/
  manifest.json
  lexicon.sqlite
  media/                 # optional, referenced local audio only
```

The manifest records format version, languages, capabilities, provenance, entry
count, database filename, and SHA-256. Pack opening checks the manifest, digest,
SQLite application/schema identifiers, integrity, entry count, local containment,
and configured limits before lookup.

## Application workflow

On Mac, open **Library → Vocabulary Packs…** and choose **Import Pack…**.
On iPhone and iPad, open **Settings → Vocabulary Packs** and choose
**Install Pack…**. NeoAnki copies the validated `.neovocab` package into
its managed library directory.

Use **Add Word → Create Cards → Find Examples** to look up a meaning and
example sentence. The meaning-recall and Cloze cards use the selected
example and retain its source. From **Add Word → Use Custom Item Type…**,
choose a dictionary, deck, and field mappings. A unique exact match fills
editable fields, including definitions, word forms, and textual pronunciation.
The custom capture stays open after each save for repeated lookup.

## Device sync

Enabling the existing iCloud opt-in automatically uploads installed dictionaries
and synchronizes their catalog on Mac and iOS. Pack bytes download on demand
from Vocabulary Packs. Local removal keeps the cloud copy and authored cards;
different versions of the same pack require an explicit replacement download.

The shared sync model caches an account-scoped catalog and coordinates bounded,
resumable transfers. Canonical manifest hashes identify immutable versions.
Transfers use 8 MiB chunks, verify file hashes, and publish catalog metadata only
after a complete upload. Downloads install through the ordinary validated pack
store; the previous version is preserved until replacement validation succeeds.

CloudKit uses a separate NeoAnkiVocabulary private zone and the existing
LibraryResource record type and fields. Catalog fetches request metadata fields
without assets; chunk assets are fetched only for an explicit download. This
requires no database, vocabulary pack format, HTTP API, or CloudKit field
migration. Real account availability, quota, and network failures are reported
in the pack list without preventing offline lookup or study.

## Verification

```sh
swift test --filter NeoAnkiVocabularyCLITests
python3 -m unittest discover -s Tools/VocabularySources/tests -v
```

Large generated packs and normalized JSONL belong under `.local/`, which is ignored
by Git. They are acceptance artifacts, not repository fixtures.
