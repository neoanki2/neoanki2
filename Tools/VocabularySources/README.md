# Offline Ukrainian vocabulary sources

This catalog is the Ukrainian acceptance-test dataset for NeoAnki's generic,
offline vocabulary pipeline. It is not application data and is not shipped in
the repository. The downloader performs network access only as an explicit
developer/deck-author preparation step; vocabulary lookup can use the resulting
files without a network connection.

Run:

```sh
Tools/VocabularySources/download-ukrainian.sh
```

The default destination is `.local/vocab-sources/ukrainian/`, which is ignored
by Git. Use `--destination PATH` to select a different location. Normal runs use
the tracked [`ukrainian-sources.lock.json`](ukrainian-sources.lock.json), verify
every existing or newly downloaded byte against its locked size and SHA-256,
and check out Git sources at exact detached commits. They never silently follow
a moving branch or `latest` URL.

The script validates every compressed archive, verifies the Wiktionary dump
against Wikimedia's locked SHA-1 manifest, reports Git LFS pointers, checks
available disk space and source-size caps, and writes a local `inventory.tsv`
with exact logical byte counts, Git commits, SHA-256 content digests, and source
URLs. An interrupted `.part` download can resume; a completed mismatch stops
with an error instead of being silently blessed.

## Build an offline pack from the local Kaikki artifact

The repository now includes a language-neutral Kaikki normalizer and the
`neoanki-vocab` Swift CLI. Neither command below downloads anything:

```sh
mkdir -p .local/vocab-packs

python3 Tools/VocabularySources/normalize_kaikki.py \
  --input .local/vocab-sources/ukrainian/archives/kaikki.org-dictionary-Ukrainian.jsonl.gz \
  --output .local/vocab-packs/kaikki-uk.jsonl \
  --language uk \
  --definition-language en \
  --tatoeba .local/vocab-sources/ukrainian/archives/tatoeba-ukr-sentences.tsv.bz2 \
  --tatoeba-language ukr \
  --tatoeba-max-examples 3 \
  --strip-combining-codepoint U+0301

swift run neoanki-vocab compile \
  --input .local/vocab-packs/kaikki-uk.jsonl \
  --output .local/vocab-packs/Kaikki-Ukrainian.neovocab \
  --id kaikki.wiktionary.uk \
  --title "Kaikki / English Wiktionary — Ukrainian" \
  --language uk \
  --capability lexicon \
  --capability pronunciation \
  --capability morphology \
  --capability corpus \
  --source-id kaikki-wiktionary \
  --source-name "Kaikki.org extraction of Wiktionary" \
  --license "CC BY-SA and GFDL; verify upstream terms"

swift run neoanki-vocab validate \
  --pack .local/vocab-packs/Kaikki-Ukrainian.neovocab
```

Kaikki's Ukrainian extract comes from English Wiktionary, so its glosses are
English. The normalizer preserves this as definition language `en`; it does not
pretend they are Ukrainian definitions. Tatoeba enrichment is token-based rather
than sense-disambiguated, so generated examples must remain author-reviewed. It
keeps exact cloze spans and per-sentence Tatoeba provenance. See
[`docs/OFFLINE_VOCABULARY.md`](../../docs/OFFLINE_VOCABULARY.md) for the format
and adapter behavior.

Updating upstream data is a separate, explicit two-phase operation:

```sh
Tools/VocabularySources/download-ukrainian.sh \
  --refresh-lock \
  --destination .local/vocab-sources/ukrainian-refresh-YYYY-MM-DD
```

Refresh mode requires an empty directory, leaves the current snapshot and
tracked lock untouched, and writes `ukrainian-sources.lock.candidate.json` next
to the candidate data. Review data, format, provenance, license, and size
changes before intentionally replacing the tracked lock. Some upstreams do not
publish immutable historical URLs, so the lock guarantees fail-closed
verification; it cannot guarantee that a moving upstream will retain old bytes
for a future first-time download.

These artifacts are not themselves `.neovocab` packs. A source adapter must
normalize selected records to `LexicalEntry` JSONL, preserve per-record
provenance, and then invoke `VocabularyPackCompiler`. Raw wikitext, StarDict,
DSL, VESUM, and corpus files cannot be selected directly in NeoAnki.

## Downloaded inventory

Retrieval date: **2026-07-31**. Locked logical payload: **955,684,791 bytes**.
The present snapshot occupies approximately **1.0 GiB**; `.git` metadata and
filesystem allocation make installed size environment-dependent.

### Archives and individual files

| Local artifact | Exact source URL | Bytes | SHA-256 |
|---|---|---:|---|
| `ukwiktionary-latest-pages-articles.xml.bz2` | `https://dumps.wikimedia.org/ukwiktionary/20260701/ukwiktionary-20260701-pages-articles.xml.bz2` | 16,524,566 | `9dacc408065a68ee7c013f891120b3149a122c7b0dd49d03e731e5121d655afa` |
| `ukwiktionary-latest-sha1sums.txt` | `https://dumps.wikimedia.org/ukwiktionary/20260701/ukwiktionary-20260701-sha1sums.txt` | 3,680 | `67006a1799e1f4781896c82fb96ba7530c73fe284519ab2bbff0e5975f20b268` |
| `kaikki.org-dictionary-Ukrainian.jsonl.gz` | `https://kaikki.org/dictionary/Ukrainian/kaikki.org-dictionary-Ukrainian.jsonl.gz` | 28,005,792 | `bfd9f0fa6e33eed01d260027ff3df08635f65ac59202f24ce7ee8c8e1c524c1f` |
| `tatoeba-ukr-sentences.tsv.bz2` | `https://downloads.tatoeba.org/exports/per_language/ukr/ukr_sentences.tsv.bz2` | 1,993,125 | `c9c469b4bef33475526c76e9693a846fb83a498d48d8eb31005a5f924ae90e53` |
| `tatoeba-ukr-sentences-CC0.tsv.bz2` | `https://downloads.tatoeba.org/exports/per_language/ukr/ukr_sentences_CC0.tsv.bz2` | 7,887 | `194ae135aafe303a2350909455b909d8e31341170e9d2b7f9a6956f0a1d4e267` |
| `leipzig-ukr-news-2020-1M.tar.gz` | `https://downloads.wortschatz-leipzig.de/corpora/ukr_news_2020_1M.tar.gz` | 197,202,391 | `d384692acbd7fe72409d53b92f1dd00feb48447c0a61158b560e6613079e6b5a` |
| `ubertext-2-frequency.csv.xz` | `https://lang.org.ua/static/downloads/ubertext2.0/dicts/ubertext_freq.csv.xz` | 89,035,796 | `407f0c0babbea71f6910dc31fee67bd2dfc9644d4278322acd834322d73536c3` |
| `Stardict.Ukr.zip` | `https://github.com/bakustarver/ukr-dictionaries-list-opensource/releases/download/0.1/Stardict.Ukr.zip` | 56,417,949 | `3e2fb0b5a8da41efcaaf2cf60c8e13f02b1150b3232acd29dff7cecdedba15f3` |
| `ABBYY.Lingvo.DSL.Ukr.zip` | `https://github.com/bakustarver/ukr-dictionaries-list-opensource/releases/download/0.1/ABBYY.Lingvo.DSL.Ukr.zip` | 93,437,034 | `0c63dad301370853e4ade8710935cfd0074da744b7b9f55cbf2013b2a06902bb` |
| `ukrainian_mfa.dict` | `https://github.com/MontrealCorpusTools/mfa-models/releases/download/dictionary-ukrainian_mfa-v3.0.0/ukrainian_mfa.dict` | 3,267,130 | `1e50679f37d3ed96c1e574fa6fce4c68cba00a9d91541306c32185a1f523e272` |
| `ukrainian_mfa-g2p-v3.0.0.zip` | `https://github.com/MontrealCorpusTools/mfa-models/releases/download/g2p-ukrainian_mfa-v3.0.0/ukrainian_mfa.zip` | 6,556,256 | `f5371a905e4eae3bab1593994efbe8ec30a9e9dd530d38a6a0dc52c0318502c1` |
| `frequencywords-uk-50k.txt` | `https://api.github.com/repos/hermitdave/FrequencyWords/contents/content/2018/uk/uk_50k.txt?ref=525f9b560de45753a5ea01069454e72e9aa541c6` | 887,259 | `881686fe66a168b79f6a9ee2f6cbbf944cfb12bfb7040913ef535cb29bd86ec9` |
| `frequencywords-uk-full.txt` | `https://api.github.com/repos/hermitdave/FrequencyWords/contents/content/2018/uk/uk_full.txt?ref=525f9b560de45753a5ea01069454e72e9aa541c6` | 5,560,013 | `bfa15b3512a41771ac8ecf47f5ef8314badb76f867fb9a6afbb409265b41709f` |
| `freedict-database.json` | `https://freedict.org/freedict-database.json` | 568,521 | `08078a2c28bb06dac716ca4b0e785621ed8bfde7c0a4aac15236c3279e2ca060` |

### Git datasets

Each worktree is detached at its locked commit. The content digest is SHA-256
over sorted, relative-path file checksums, excluding `.git`. `Bytes` below are
exact logical worktree bytes, not allocated disk blocks and not Git history.

| Repository | Commit | Bytes | Content SHA-256 |
|---|---|---:|---|
| `https://github.com/brown-uk/corpus.git` | `0665e895834c6a20acb1b48e58ba07e149c31f32` | 76,330,480 | `5840e11d8996af6107a644ca85f5444f70532aef3e95e54b687a8b102e9b57d9` |
| `https://github.com/lang-uk/ipa-uk.git` | `e7fc944faca090ca985d5ca09a24c59154d9dea1` | 2,013,266 | `13df5f6d1639cadc01f85cb7c1ad4ca2f8749624cfce298274e598b51413f1e4` |
| `https://github.com/lang-uk/wordnet.git` | `22faf275aeebfcb07b760350f22e1ba90d930728` | 22,396,769 | `7917cd91fd003db3868aa3e7e09a00ac13e351939c52a9cf97132aac80a82976` |
| `https://github.com/UniversalDependencies/UD_Ukrainian-IU.git` | `21f641ba6109044ce9aafd4b2cbfa20a4ac6e479` | 17,524,942 | `82d42ad0f73084bce48cb2c13cc5c8ead929061db158741801ef8bab137a013a` |
| `https://github.com/UniversalDependencies/UD_Ukrainian-ParlaMint.git` | `7d3fcb7e207e3d36fec4d5f27070a23db2b9a996` | 10,456,570 | `3902f154e8aa71cb1a670742af24c371aa7393b1b84e503baf66b17f054fe88e` |
| `https://github.com/lang-uk/ukrainian-heteronyms-dictionary.git` | `88f6a917a989b140332b8a573443de1918499acd` | 2,267,526 | `220d3417224feafc76082aa33ccade38d4b1a0cc9a08fdc890baa1f3f333b0ca` |
| `https://github.com/lang-uk/ukrainian-tts-preprocessing.git` | `f090a78a2a03fe94840013baafd6073a25dffa47` | 12,907,787 | `eff0cb7a4821688fc61daeebbab64435fbf4f5f6bfd0670fe2b541059fdbb7c4` |
| `https://github.com/lang-uk/ukrainian-word-stress.git` | `541d33edf89042913006c50968f91fd48a2b71db` | 12,644,613 | `97110007c4528de5b0378906dfaf8f3b5e8ed5dc58d3dcbec5f1d88b2080e71e` |
| `https://github.com/lang-uk/ukrainian-word-stress-dictionary.git` | `92544220a49018dc560d13c82cb8088f511f720b` | 72,013,594 | `2093f88cae04dd8d23006eeae76923c060c700ef934368070803a30f3b7fa040` |
| `https://github.com/hdaSprachtechnologie/ukrajinet.git` | `a0d5437bb2d9438093756f85f3c1439be12c3692` | 175,925,301 | `95cd8e52c9f1c9697fca63e3b5beb1f40a789f1b67bab93ed0abc26b4cfff91e` |
| `https://github.com/unimorph/ukr.git` | `d7d0284e926b7d4947c52aaafd1d7f8a40a2dec0` | 25,242,369 | `fc658910b3c949af675b357dc21d7bb32c73040c77bec6009867042d5edfd103` |
| `https://github.com/brown-uk/dict_uk.git` (VESUM) | `5bb6e49693c55b7634e430fae14720aebe5a33d3` | 26,494,175 | `0d24cefa114dab3ba70954a1cafd4095d92d2f460528193b5baabc248c9d63b6` |

## Capabilities, formats, and provenance

All lexical languages are Ukrainian (`uk`/`ukr`) unless a second language is
listed. Licenses are recorded for provenance, not used here as a download
filter. A future distributable pack must perform its own license review.

| Source | Capability and format | License/provenance notes |
|---|---|---|
| Ukrainian Wiktionary dump | Ukrainian-language definitions, forms, etymology, pronunciation templates and examples; MediaWiki XML + wikitext | Wikimedia/Wiktionary content terms, primarily CC BY-SA; individual contributions and embedded material can have additional attribution requirements. |
| Kaikki Ukrainian extract | Ukrainian entries extracted from **English** Wiktionary: English glosses, forms, IPA, pronunciation metadata and occasional examples; JSONL | Derived from Wiktionary by Wiktextract; Wiktionary CC BY-SA/GFDL provenance. This is complementary, not a Ukrainian-definition replacement. |
| StarDict/DSL bundle | SUM-11 Ukrainian definitions; English–Ukrainian Balla; Ukrainian Wiktionary; Hrinchenko; phraseological, foreign-word and terminology dictionaries; StarDict and ABBYY DSL | Mixed and incompletely declared licenses. Treat each contained dictionary as a separate provenance unit. Personal-use availability does not imply redistribution rights. |
| Stress dictionary | 2,931,548 lines of stressed wordforms using combining acute `U+0301`; UTF-8 text | Derived from ULIF “Dictionaries of Ukraine”; repository has no declared license. |
| Heteronyms dictionary | 37,354 headword-to-stress-variant records; TSV | Derived from ULIF by Oleksii Syvokon; repository has no declared license. |
| `ukrainian-word-stress` | Offline trie and context-aware stress code; Python/marisa-trie data | Code MIT; lexical-data provenance traces to the stress dictionary above. Dictionary mode is offline. Default contextual mode can download about 500 MB of Stanza models and must not be invoked by an offline adapter without a preinstalled local model. |
| `ipa-uk` | Deterministic Ukrainian stressed-text to IPA conversion; Python | MIT; algorithm ported from Ukrainian Wiktionary's pronunciation module. |
| Ukrainian TTS preprocessing | Stress model integration, phonemizer, and 1,026 manually annotated benchmark sentences; Python/CSV/model metadata | Apache-2.0 repository. The locked worktree intentionally contains a 133-byte Git LFS pointer for the 39,433,575-byte `voa_stressed_cleaned_data.csv`; that training file is **not downloaded**. The default processor calls Hugging Face without a local model path, so it is quarantined from offline runtime use. |
| MFA dictionary and G2P | Word-to-phone pronunciations and an offline grapheme-to-phoneme FST; MFA dictionary/ZIP | CC BY 4.0. Intended for alignment, but useful as a generic pronunciation representation. |
| VESUM (`dict_uk`) | Lemmas, paradigms, POS, grammatical features and generated forms; source lists/rules | Dictionary data CC BY-NC-SA 4.0; generator code GPL-3.0-or-later. |
| UniMorph Ukrainian | VESUM conversion plus a Wiktionary-derived paradigm file; TSV/XZ | VESUM conversion CC BY-NC-SA 4.0; Wiktionary file CC BY-SA 3.0. |
| Tatoeba Ukrainian | 188,659 example sentences; TSV/BZip2 | Main export CC BY 2.0 FR. The separately published `_CC0` file is only 393 rows, so it is a high-confidence licensing subset rather than broad coverage. User/date attribution columns differ between files. |
| UD Ukrainian IU | About 7,060 manually annotated sentences/122K tokens with lemmas, POS and morphology; CoNLL-U | CC BY-NC-SA 4.0. |
| UD Ukrainian ParlaMint | Ukrainian parliamentary examples with manually checked lemmas/morphosyntax; CoNLL-U | CC BY-SA 4.0; source transcripts include parliamentary provenance. |
| Brown Ukrainian corpus | Balanced, curated Ukrainian text fragments usable for example extraction; plain text | CC BY-NC-SA 4.0. Per-text source metadata remains relevant. |
| Leipzig Ukrainian News 2020 1M | One million shuffled news sentences, source map, word frequencies and co-occurrence tables; TSV-like text in TAR/GZip | Leipzig download terms state downloadable text corpora are CC BY; source sentences originated in news material and retain source metadata. |
| UberText 2 frequency dictionary | Lemma/POS counts, document counts and normalized frequency; CSV/XZ | Statistical derivative of the mixed-source UberText 2 corpus. The project describes fair-use/scientific-analysis conditions for some source text; review before redistribution. |
| FrequencyWords Ukrainian | Surface-word frequencies from OpenSubtitles 2018; plain `word count` text | Content CC BY-SA 4.0; generator code MIT. |
| Ukrajinet | Ukrainian WordNet definitions, lemmas, synsets and relations; WN-LMF XML | XML declares CC BY-SA 4.0; built from Ukrainian physics dictionaries plus an automatic Open English WordNet translation. |
| `lang-uk/wordnet` | Ukrainian WordNet research artifacts and extracted relation candidates; CSV/JSON/notebooks | No repository-wide license declared. Experimental rather than production-authoritative. |
| FreeDict catalog | Machine-readable catalog of all current FreeDict releases; JSON | No Ukrainian (`ukr`) source or target dictionary was present on 2026-07-31. The catalog is retained so this negative result is auditable and recheckable. |

## Practical adapter order for Ukrainian card building

1. Use SUM-11 from the StarDict bundle or Ukrainian Wiktionary for
   Ukrainian-language definitions and examples.
2. Resolve lemma and the sentence's actual inflected form with VESUM. UniMorph
   is a simpler interchange alternative.
3. Add a pronunciation representation from the stress dictionary; retain all
   variants for entries found in the heteronym table. Add IPA with `ipa-uk` or
   MFA phones as optional additional representations.
4. Prefer definition-attached examples; otherwise search Tatoeba, then the
   manually annotated UD corpora. Leipzig and Brown provide broader fallbacks.
5. Rank candidates with UberText lemma frequency; use FrequencyWords when only
   surface-form counts are needed.
6. Keep source identity and attribution on every normalized entry, sense,
   pronunciation and example. Do not flatten provenance when combining packs.

## Verification performed

- All BZip2, GZip, XZ, ZIP and TAR archives passed their native integrity tests.
- Archive integrity is not extraction authorization. Future adapters must reject
  absolute and parent paths, links, excessive entry counts, and excessive
  expanded sizes. The current ZIP/TAR members were separately scanned: no
  traversal paths or links were found, and expansion ratios were below 6.3x.
- The Wiktionary archive's SHA-1 matched Wikimedia's dated dump entry
  (`010480761e7c2e54d494d7b583e489f322a929c6`).
- Kaikki's first record parsed as JSON and contained word, form, sense and sound
  structures.
- Tatoeba full and CC0 exports yielded valid Ukrainian TSV records.
- Leipzig contained sentences, sources, words, inverse indexes and
  co-occurrence tables.
- UberText's CSV header and lemma/POS/count rows were inspected.
- The stress dictionary contained 2,931,548 records and returned the expected
  `застосува́…` forms; the heteronym table contained 37,354 records.
- VESUM contained the lemma `застосувати`; UniMorph produced tabular paradigms.
- Both UD corpora yielded sentence text and token-level CoNLL-U annotation.
- Ukrajinet opened as WN-LMF XML and declared its language and license.
- MFA dictionary rows and G2P model members were inspected.
- All repositories matched exact detached commits and content hashes. The one
  expected Git LFS pointer is locked and reported; any additional pointer fails
  verification.

## Large or unavailable sources not downloaded

| Source | Status and reason |
|---|---|
| Mozilla Common Voice Ukrainian 23 | Optional, about 2.55 GB. CC0 sentence audio is useful for listening cards but is not a word-pronunciation dictionary, requires accepting dataset conditions, and prohibits rehosting. Download manually from Mozilla Data Collective when needed. |
| Voice of America Ukrainian ASR corpus | Optional, about 15.1 GB/398 hours. Broadcast audio is valuable for speech research but disproportionate for word-card generation. |
| Full UberText 2 layers | Optional, from roughly 87 MB to 3.5 GB per layer. The compact 89 MB lemma-frequency dictionary was downloaded; use the source page to select a sentence/token layer only if Leipzig/UD/Brown are insufficient. |
| GRAC | Not downloaded. It is an excellent online corpus, but no supported bulk dataset download suitable for an offline adapter was found. |
| Lingua Libre/Wikimedia Commons Ukrainian pronunciation audio | Not downloaded. More than 16K individual Commons pronunciation files exist, but no verified Ukrainian bulk package was found; crawling individual files was intentionally avoided. |
| FreeDict Ukrainian dictionary | Not found in the current FreeDict API catalog. |
