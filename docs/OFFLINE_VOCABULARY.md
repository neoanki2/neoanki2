---
title: Offline vocabulary packs
description: Normalize local lexical datasets, compile .neovocab packs, validate them, and search without network access.
parent: Reference
---

# Offline vocabulary packs

NeoAnki vocabulary lookup is local-only. The user imports a `.neovocab`
directory once; the application validates and copies it into library-managed
storage, then queries its read-only SQLite index. It has no vocabulary download
client. Source acquisition is an explicit deck-author or developer operation
performed before import.

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

1. Choose **File → Import Vocabulary Pack…** and select the `.neovocab`
   directory. NeoAnki copies the validated package into its managed library
   directory; it does not keep a bookmark or live link to the source.
2. Select an existing deck.
3. Choose **Add from Vocabulary…**, select an installed pack, and search.
4. Review the generated cards and choose **Add Cards**. The generated authored
   item batch is validated and appended atomically to the selected deck without
   creating a child deck.

The add window remains open after a successful import so multiple words can be
captured in one session.

## Verification

```sh
swift test --filter NeoAnkiVocabularyCLITests
python3 -m unittest discover -s Tools/VocabularySources/tests -v
```

Large generated packs and normalized JSONL belong under `.local/`, which is ignored
by Git. They are acceptance artifacts, not repository fixtures.
