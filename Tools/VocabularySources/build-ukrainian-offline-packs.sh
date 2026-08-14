#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_ROOT="$REPO_ROOT/.local/vocab-sources/ukrainian"
PACK_ROOT="$REPO_ROOT/.local/vocab-packs"
ARCHIVE="$SOURCE_ROOT/archives/Stardict.Ukr.zip"
STRESS="$SOURCE_ROOT/github/ukrainian-word-stress-dictionary/stress.txt"
HETERONYMS="$SOURCE_ROOT/github/ukrainian-heteronyms-dictionary/heteronyms.tsv"
FREQUENCY="$SOURCE_ROOT/archives/ubertext-2-frequency.csv.xz"
NORMALIZER="$REPO_ROOT/Tools/VocabularySources/normalize_stardict_ukrainian.py"
CACHE_BUILDER="$REPO_ROOT/Tools/VocabularySources/build_ukrainian_source_cache.py"

for command_name in jq python3 shasum swift; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

for source_file in "$ARCHIVE" "$STRESS" "$HETERONYMS" "$FREQUENCY"; do
  [[ -f "$source_file" ]] || {
    echo "Locked Ukrainian source is missing: $source_file" >&2
    exit 1
  }
done

expected_archive_sha="$(
  jq -r '.files[] | select(.path == "archives/Stardict.Ukr.zip") | .sha256' \
    "$REPO_ROOT/Tools/VocabularySources/ukrainian-sources.lock.json"
)"
actual_archive_sha="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$expected_archive_sha" == "$actual_archive_sha" ]] || {
  echo "Locked StarDict archive checksum mismatch." >&2
  exit 1
}

mkdir -p "$PACK_ROOT"

SUM_JSONL="$PACK_ROOT/sum11-uk.jsonl"
RUUK_JSONL="$PACK_ROOT/ruuk-aligned.jsonl"
SUM_PACK="$PACK_ROOT/SUM11-Ukrainian.neovocab"
RUUK_PACK="$PACK_ROOT/Russian-Ukrainian-Aligned.neovocab"
SUM_PACK_STAGING="$PACK_ROOT/SUM11-Ukrainian.part.neovocab"
RUUK_PACK_STAGING="$PACK_ROOT/Russian-Ukrainian-Aligned.part.neovocab"
CACHE="$PACK_ROOT/ukrainian-source-cache.sqlite"
MARKER="$PACK_ROOT/ukrainian-offline-stack.sha256"

source_fingerprint="$(
  {
    shasum -a 256 "$ARCHIVE" "$STRESS" "$HETERONYMS" "$FREQUENCY"
    shasum -a 256 "$NORMALIZER" "$CACHE_BUILDER"
  } | shasum -a 256 | awk '{print $1}'
)"

if [[ -f "$MARKER" && "$(<"$MARKER")" == "$source_fingerprint" \
      && -d "$SUM_PACK" && -d "$RUUK_PACK" && -f "$CACHE" ]]; then
  swift run --package-path "$REPO_ROOT" neoanki-vocab validate --pack "$SUM_PACK"
  swift run --package-path "$REPO_ROOT" neoanki-vocab validate --pack "$RUUK_PACK"
  echo "Offline Ukrainian source stack is already current: $PACK_ROOT"
  exit 0
fi

[[ ! -e "$SUM_PACK" && ! -e "$RUUK_PACK" ]] || {
  echo "Existing output packs do not match the current source fingerprint; refusing to overwrite." >&2
  exit 1
}

python3 "$NORMALIZER" --input "$ARCHIVE" --output "$SUM_JSONL" --dictionary sum11
[[ ! -e "$SUM_PACK_STAGING" && ! -e "$RUUK_PACK_STAGING" ]] || {
  echo "Stale partial pack directory exists; inspect it before rebuilding." >&2
  exit 1
}
swift run --package-path "$REPO_ROOT" neoanki-vocab compile \
  --input "$SUM_JSONL" \
  --output "$SUM_PACK_STAGING" \
  --id stardict.sum11.uk.v3 \
  --title "SUM-11 — Ukrainian definitions (v3)" \
  --summary "Locked local SUM-11 short definitions and stressed headwords" \
  --language uk \
  --capability lexicon \
  --source-id stardict-sum11 \
  --source-name "SUM-11 from locked StarDict Ukrainian bundle" \
  --license "Mixed upstream dictionary terms; personal local use only" \
  --source-url "${SOURCE_URL:-https://github.com/bakustarver/ukr-dictionaries-list-opensource/releases/download/0.1/Stardict.Ukr.zip}"
mv "$SUM_PACK_STAGING" "$SUM_PACK"
unlink "$SUM_JSONL"

python3 "$NORMALIZER" --input "$ARCHIVE" --output "$RUUK_JSONL" --dictionary ruuk

swift run --package-path "$REPO_ROOT" neoanki-vocab compile \
  --input "$RUUK_JSONL" \
  --output "$RUUK_PACK_STAGING" \
  --id stardict.ruuk.aligned \
  --title "Russian–Ukrainian aligned lookup" \
  --summary "Russian headwords indexed by exact Ukrainian translation spans" \
  --language ru \
  --language uk \
  --capability lexicon \
  --source-id stardict-ruuk-big \
  --source-name "Large Russian–Ukrainian dictionary from locked StarDict bundle" \
  --license "Mixed upstream dictionary terms; personal local use only" \
  --source-url "${SOURCE_URL:-https://github.com/bakustarver/ukr-dictionaries-list-opensource/releases/download/0.1/Stardict.Ukr.zip}"
mv "$RUUK_PACK_STAGING" "$RUUK_PACK"
unlink "$RUUK_JSONL"

swift run --package-path "$REPO_ROOT" neoanki-vocab validate --pack "$SUM_PACK"
swift run --package-path "$REPO_ROOT" neoanki-vocab validate --pack "$RUUK_PACK"

python3 "$CACHE_BUILDER" \
  --stress "$STRESS" \
  --heteronyms "$HETERONYMS" \
  --frequency "$FREQUENCY" \
  --output "$CACHE"

printf '%s\n' "$source_fingerprint" > "$MARKER"

echo "Offline Ukrainian source stack is ready: $PACK_ROOT"
