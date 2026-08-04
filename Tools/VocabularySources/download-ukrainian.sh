#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCK_FILE="$REPO_ROOT/Tools/VocabularySources/ukrainian-sources.lock.json"
DESTINATION="$REPO_ROOT/.local/vocab-sources/ukrainian"
REFRESH_MODE=0
MAX_SOURCE_BYTES="${NEOANKI_VOCAB_MAX_SOURCE_BYTES:-1000000000}"
MINIMUM_FREE_RESERVE_BYTES="${NEOANKI_VOCAB_FREE_RESERVE_BYTES:-2147483648}"

[[ "$MAX_SOURCE_BYTES" =~ ^[0-9]+$ && "$MINIMUM_FREE_RESERVE_BYTES" =~ ^[0-9]+$ ]] || {
  echo "Vocabulary source byte caps must be non-negative integers." >&2
  exit 2
}

usage() {
  cat <<'USAGE'
Usage:
  download-ukrainian.sh [--destination PATH]
  download-ukrainian.sh --refresh-lock --destination EMPTY_PATH

Normal mode downloads and verifies the exact tracked lock. It never follows a
moving branch or "latest" URL silently. Refresh mode follows refresh endpoints
into a separate empty directory and writes a candidate lock beside that data;
it never overwrites the tracked lock or the normal source snapshot.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      DESTINATION="$2"
      shift 2
      ;;
    --refresh-lock)
      REFRESH_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command_name in awk bzip2 cat cp curl date df dirname find gh git gzip jq \
  mkdir mv rg sed shasum sort stat tar tr unzip wc xargs xz; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

jq -e '.schemaVersion == 1 and (.files | type == "array") and (.repositories | type == "array")' \
  "$LOCK_FILE" >/dev/null || {
    echo "Invalid vocabulary source lock: $LOCK_FILE" >&2
    exit 1
  }

if [[ "$REFRESH_MODE" -eq 1 ]]; then
  if [[ "$DESTINATION" == "$REPO_ROOT/.local/vocab-sources/ukrainian" ]]; then
    echo "Refresh mode requires an explicit separate --destination." >&2
    exit 2
  fi
  if [[ -e "$DESTINATION" ]] && [[ -n "$(find "$DESTINATION" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Refresh destination must be empty: $DESTINATION" >&2
    exit 2
  fi
fi

ARCHIVES="$DESTINATION/archives"
REPOSITORIES="$DESTINATION/github"
METADATA="$DESTINATION/metadata"
mkdir -p "$ARCHIVES" "$REPOSITORIES" "$METADATA"

logical_file_size() {
  stat -f '%z' "$1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

repository_logical_bytes() {
  find "$1" -type f ! -path '*/.git/*' -exec stat -f '%z' {} + \
    | awk '{ total += $1 } END { printf "%.0f", total }'
}

repository_content_sha256() {
  (
    cd "$1"
    find . -type f ! -path './.git/*' -print0 \
      | sort -z \
      | xargs -0 shasum -a 256 \
      | shasum -a 256 \
      | awk '{print $1}'
  )
}

lfs_pointer_list() {
  local repository="$1"
  (
    cd "$repository"
    rg -l '^version https://git-lfs.github.com/spec/v1$' . \
      -g '!/.git/**' 2>/dev/null \
      | sed 's#^\./##' \
      | sort || true
  )
}

available_bytes() {
  df -Pk "$DESTINATION" | awk 'NR == 2 { printf "%.0f", $4 * 1024 }'
}

preflight_locked_size() {
  local locked_total missing_total available
  locked_total="$(jq '[.files[].bytes, .repositories[].logicalBytes] | add' "$LOCK_FILE")"
  local lock_cap
  lock_cap="$(jq -r '.maximumLockedBytes' "$LOCK_FILE")"
  if (( locked_total > lock_cap )); then
    echo "Locked sources exceed the lock's total byte cap." >&2
    exit 1
  fi

  missing_total=0
  while IFS=$'\t' read -r path bytes; do
    [[ -e "$DESTINATION/$path" ]] || missing_total=$((missing_total + bytes))
  done < <(jq -r '.files[] | [.path, .bytes] | @tsv' "$LOCK_FILE")
  while IFS=$'\t' read -r path bytes; do
    # Git history and indexes are not represented by logical worktree bytes.
    [[ -d "$DESTINATION/$path/.git" ]] || missing_total=$((missing_total + bytes * 3))
  done < <(jq -r '.repositories[] | [.path, .logicalBytes] | @tsv' "$LOCK_FILE")

  available="$(available_bytes)"
  if (( missing_total + MINIMUM_FREE_RESERVE_BYTES > available )); then
    echo "Insufficient disk space: need approximately $missing_total bytes plus reserve." >&2
    exit 1
  fi
}

download_http() {
  local url="$1" output="$2"
  local remote_bytes
  remote_bytes="$(
    curl --fail --silent --show-error --head --location --connect-timeout 30 "$url" \
      | tr -d '\r' \
      | awk 'tolower($1) == "content-length:" { value = $2 } END { print value }'
  )"
  if [[ "$remote_bytes" =~ ^[0-9]+$ ]] && (( remote_bytes > MAX_SOURCE_BYTES )); then
    echo "Remote source exceeds per-file cap: $url ($remote_bytes bytes)" >&2
    exit 1
  fi
  curl --fail --location --retry 4 --retry-all-errors \
    --connect-timeout 30 --continue-at - --output "$output.part" "$url"
  mv "$output.part" "$output"
}

download_github_release() {
  local repository="$1" tag="$2" asset="$3" output="$4"
  local remote_bytes
  remote_bytes="$(gh release view "$tag" --repo "$repository" --json assets \
    --jq ".assets[] | select(.name == \"$asset\") | .size")"
  [[ "$remote_bytes" =~ ^[0-9]+$ ]] || { echo "Release asset not found: $asset" >&2; exit 1; }
  (( remote_bytes <= MAX_SOURCE_BYTES )) || {
    echo "Release asset exceeds per-file cap: $asset ($remote_bytes bytes)" >&2
    exit 1
  }
  gh release download "$tag" --repo "$repository" --pattern "$asset" \
    --output "$output.part"
  mv "$output.part" "$output"
}

download_github_api_file() {
  local repository="$1" api_path="$2" ref="$3" output="$4"
  local remote_bytes
  remote_bytes="$(gh api "repos/$repository/contents/$api_path?ref=$ref" --jq .size)"
  [[ "$remote_bytes" =~ ^[0-9]+$ ]] || { echo "GitHub file size unavailable: $api_path" >&2; exit 1; }
  (( remote_bytes <= MAX_SOURCE_BYTES )) || {
    echo "GitHub file exceeds per-file cap: $api_path ($remote_bytes bytes)" >&2
    exit 1
  }
  gh api "repos/$repository/contents/$api_path?ref=$ref" \
    -H "Accept: application/vnd.github.raw+json" > "$output.part"
  mv "$output.part" "$output"
}

validate_file_format() {
  local file="$1" validation="$2"
  case "$validation" in
    bzip2) bzip2 -t "$file" ;;
    gzip) gzip -t "$file" ;;
    xz) xz -t "$file" ;;
    tar-gzip) tar -tzf "$file" >/dev/null ;;
    zip) unzip -tq "$file" >/dev/null ;;
    json) jq -e 'type == "array" or type == "object"' "$file" >/dev/null ;;
    sha1-manifest) rg -q '^[0-9a-f]{40}  .+' "$file" ;;
    word-count)
      awk 'NF != 2 || $2 !~ /^[0-9]+$/ { exit 1 } END { if (NR == 0) exit 1 }' "$file"
      ;;
    mfa-dictionary)
      awk -F '\t' 'NF < 2 { exit 1 } END { if (NR == 0) exit 1 }' "$file"
      ;;
    *) echo "Unknown validation type: $validation" >&2; exit 1 ;;
  esac
}

verify_locked_file() {
  local output="$1" expected_bytes="$2" expected_sha="$3" validation="$4"
  local actual_bytes actual_sha
  actual_bytes="$(logical_file_size "$output")"
  actual_sha="$(sha256_file "$output")"
  if [[ "$actual_bytes" != "$expected_bytes" || "$actual_sha" != "$expected_sha" ]]; then
    echo "Locked file mismatch: $output" >&2
    echo "Expected $expected_bytes bytes / $expected_sha" >&2
    echo "Actual   $actual_bytes bytes / $actual_sha" >&2
    return 1
  fi
  validate_file_format "$output" "$validation"
}

ensure_locked_file() {
  local record="$1"
  local path kind url bytes sha validation repository tag asset api_path ref output
  path="$(jq -r '.path' <<<"$record")"
  kind="$(jq -r '.kind' <<<"$record")"
  url="$(jq -r '.url' <<<"$record")"
  bytes="$(jq -r '.bytes' <<<"$record")"
  sha="$(jq -r '.sha256' <<<"$record")"
  validation="$(jq -r '.validation' <<<"$record")"
  output="$DESTINATION/$path"
  mkdir -p "$(dirname "$output")"

  if (( bytes > MAX_SOURCE_BYTES )); then
    echo "Locked source exceeds per-file cap: $path ($bytes bytes)" >&2
    exit 1
  fi
  if [[ -s "$output" ]]; then
    verify_locked_file "$output" "$bytes" "$sha" "$validation"
    echo "Verified locked file: $path"
    return
  fi

  echo "Downloading locked source: $url"
  case "$kind" in
    http) download_http "$url" "$output" ;;
    github-release)
      repository="$(jq -r '.repository' <<<"$record")"
      tag="$(jq -r '.tag' <<<"$record")"
      asset="$(jq -r '.asset' <<<"$record")"
      download_github_release "$repository" "$tag" "$asset" "$output"
      ;;
    github-api)
      repository="$(jq -r '.repository' <<<"$record")"
      api_path="$(jq -r '.apiPath' <<<"$record")"
      ref="$(jq -r '.ref' <<<"$record")"
      download_github_api_file "$repository" "$api_path" "$ref" "$output"
      ;;
    *) echo "Unknown source kind: $kind" >&2; exit 1 ;;
  esac
  verify_locked_file "$output" "$bytes" "$sha" "$validation"
}

ensure_locked_repository() {
  local record="$1"
  local path repository commit expected_bytes expected_sha directory
  local actual_commit actual_bytes actual_sha expected_lfs actual_lfs
  path="$(jq -r '.path' <<<"$record")"
  repository="$(jq -r '.repository' <<<"$record")"
  commit="$(jq -r '.commit' <<<"$record")"
  expected_bytes="$(jq -r '.logicalBytes' <<<"$record")"
  expected_sha="$(jq -r '.contentSHA256' <<<"$record")"
  directory="$DESTINATION/$path"

  if [[ ! -d "$directory/.git" ]]; then
    [[ ! -e "$directory" ]] || {
      echo "Partial/non-Git repository path exists: $directory" >&2
      exit 1
    }
    echo "Cloning locked repository: $repository"
    GIT_LFS_SKIP_SMUDGE=1 gh repo clone "$repository" "$directory" -- \
      --no-checkout --single-branch --filter=blob:none
  fi
  if ! git -C "$directory" diff --quiet || ! git -C "$directory" diff --cached --quiet; then
    echo "Refusing to modify dirty source checkout: $directory" >&2
    exit 1
  fi
  git -C "$directory" cat-file -e "$commit^{commit}" 2>/dev/null || {
    echo "Locked commit is absent from clone: $repository@$commit" >&2
    exit 1
  }
  actual_commit="$(git -C "$directory" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$actual_commit" != "$commit" ]] || [[ -n "$(git -C "$directory" symbolic-ref -q HEAD || true)" ]]; then
    GIT_LFS_SKIP_SMUDGE=1 git -C "$directory" checkout --detach "$commit" >/dev/null
  fi
  actual_commit="$(git -C "$directory" rev-parse HEAD)"
  [[ "$actual_commit" == "$commit" ]] || { echo "Commit mismatch: $directory" >&2; exit 1; }

  actual_bytes="$(repository_logical_bytes "$directory")"
  actual_sha="$(repository_content_sha256 "$directory")"
  if [[ "$actual_bytes" != "$expected_bytes" || "$actual_sha" != "$expected_sha" ]]; then
    echo "Locked repository content mismatch: $repository@$commit" >&2
    echo "Expected $expected_bytes bytes / $expected_sha" >&2
    echo "Actual   $actual_bytes bytes / $actual_sha" >&2
    exit 1
  fi

  expected_lfs="$(jq -r '.expectedLFSPointers[]?' <<<"$record" | sort)"
  actual_lfs="$(lfs_pointer_list "$directory")"
  if [[ "$actual_lfs" != "$expected_lfs" ]]; then
    echo "Unexpected Git LFS pointer set in $repository:" >&2
    printf '%s\n' "$actual_lfs" >&2
    exit 1
  fi
  if [[ -n "$actual_lfs" ]]; then
    echo "NOTICE: locked Git LFS pointer(s) are not downloaded in $repository:"
    while IFS= read -r pointer; do printf '  %s\n' "$pointer"; done <<< "$actual_lfs"
  fi
  echo "Verified locked repository: $repository@$commit"
}

write_inventory() {
  local inventory="$DESTINATION/inventory.tsv"
  {
    printf 'kind\tpath\tlogical_bytes\tversion\tsha256\tsource_url\n'
    while IFS= read -r record; do
      local path output bytes sha url
      path="$(jq -r '.path' <<<"$record")"
      output="$DESTINATION/$path"
      bytes="$(logical_file_size "$output")"
      sha="$(sha256_file "$output")"
      url="$(jq -r '.url' <<<"$record")"
      printf 'file\t%s\t%s\t\t%s\t%s\n' "$path" "$bytes" "$sha" "$url"
    done < <(jq -c '.files[]' "$LOCK_FILE")
    while IFS= read -r record; do
      local path directory bytes sha commit repository
      path="$(jq -r '.path' <<<"$record")"
      directory="$DESTINATION/$path"
      bytes="$(repository_logical_bytes "$directory")"
      sha="$(repository_content_sha256 "$directory")"
      commit="$(git -C "$directory" rev-parse HEAD)"
      repository="$(jq -r '.repository' <<<"$record")"
      printf 'git\t%s\t%s\t%s\t%s\thttps://github.com/%s.git\n' \
        "$path" "$bytes" "$commit" "$sha" "$repository"
    done < <(jq -c '.repositories[]' "$LOCK_FILE")
  } > "$inventory"
  echo "Inventory: $inventory"
}

refresh_lock() {
  # Refresh is intentionally isolated from the normal snapshot. The implementation
  # downloads current HTTP/GitHub-file bytes and current repository heads, then
  # writes a candidate lock for human review. Release-tag sources remain on their
  # explicit tags but are rehashed in case an upstream asset was replaced.
  local candidate="$DESTINATION/ukrainian-sources.lock.candidate.json"
  preflight_locked_size
  cp "$LOCK_FILE" "$candidate"
  while IFS= read -r record; do
    local path kind url repository api_path ref output bytes sha validation tmp
    path="$(jq -r '.path' <<<"$record")"
    kind="$(jq -r '.kind' <<<"$record")"
    url="$(jq -r '.refreshURL // .url' <<<"$record")"
    ref="$(jq -r '.ref // ""' <<<"$record")"
    output="$DESTINATION/$path"
    mkdir -p "$(dirname "$output")"
    case "$kind" in
      http) download_http "$url" "$output" ;;
      github-release)
        download_github_release \
          "$(jq -r '.repository' <<<"$record")" \
          "$(jq -r '.tag' <<<"$record")" \
          "$(jq -r '.asset' <<<"$record")" "$output"
        ;;
      github-api)
        repository="$(jq -r '.repository' <<<"$record")"
        api_path="$(jq -r '.apiPath' <<<"$record")"
        ref="$(gh api "repos/$repository/commits/$(jq -r '.refreshRef' <<<"$record")" --jq .sha)"
        url="https://api.github.com/repos/$repository/contents/$api_path?ref=$ref"
        download_github_api_file "$repository" "$api_path" "$ref" "$output"
        ;;
    esac
    bytes="$(logical_file_size "$output")"
    (( bytes <= MAX_SOURCE_BYTES )) || { echo "Refreshed source exceeds cap: $path" >&2; exit 1; }
    validation="$(jq -r '.validation' <<<"$record")"
    validate_file_format "$output" "$validation"
    sha="$(sha256_file "$output")"
    tmp="$candidate.tmp"
    jq --arg path "$path" --arg url "$url" --arg ref "$ref" \
      --argjson bytes "$bytes" --arg sha "$sha" \
      '(.files[] | select(.path == $path)) |=
       (.url = $url | .bytes = $bytes | .sha256 = $sha |
        if .kind == "github-api" then .ref = $ref else . end)' \
      "$candidate" > "$tmp"
    mv "$tmp" "$candidate"
  done < <(jq -c '.files[]' "$LOCK_FILE")

  while IFS= read -r record; do
    local path repository directory commit bytes sha pointers pointer_json tmp
    path="$(jq -r '.path' <<<"$record")"
    repository="$(jq -r '.repository' <<<"$record")"
    directory="$DESTINATION/$path"
    GIT_LFS_SKIP_SMUDGE=1 gh repo clone "$repository" "$directory" -- --depth 1
    commit="$(git -C "$directory" rev-parse HEAD)"
    GIT_LFS_SKIP_SMUDGE=1 git -C "$directory" checkout --detach "$commit" >/dev/null
    bytes="$(repository_logical_bytes "$directory")"
    sha="$(repository_content_sha256 "$directory")"
    pointers="$(lfs_pointer_list "$directory")"
    pointer_json="$(printf '%s\n' "$pointers" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    tmp="$candidate.tmp"
    jq --arg path "$path" --arg commit "$commit" --argjson bytes "$bytes" \
      --arg sha "$sha" --argjson pointers "$pointer_json" \
      '(.repositories[] | select(.path == $path)) |=
       (.commit = $commit | .logicalBytes = $bytes | .contentSHA256 = $sha | .expectedLFSPointers = $pointers)' \
      "$candidate" > "$tmp"
    mv "$tmp" "$candidate"
  done < <(jq -c '.repositories[]' "$LOCK_FILE")

  local tmp="$candidate.tmp"
  jq --arg date "$(date -u +%F)" '.retrievalDate = $date' "$candidate" > "$tmp"
  mv "$tmp" "$candidate"
  local candidate_total lock_cap
  candidate_total="$(jq '[.files[].bytes, .repositories[].logicalBytes] | add' "$candidate")"
  lock_cap="$(jq -r '.maximumLockedBytes' "$candidate")"
  (( candidate_total <= lock_cap )) || {
    echo "Refresh candidate exceeds maximumLockedBytes." >&2
    exit 1
  }
  echo "Refresh candidate written to: $candidate"
  echo "Review source/license changes, then intentionally replace the tracked lock in a separate step."
}

if [[ "$REFRESH_MODE" -eq 1 ]]; then
  refresh_lock
  exit 0
fi

preflight_locked_size
while IFS= read -r record; do ensure_locked_file "$record"; done < <(jq -c '.files[]' "$LOCK_FILE")
while IFS= read -r record; do ensure_locked_repository "$record"; done < <(jq -c '.repositories[]' "$LOCK_FILE")

# Cross-check the locked Wikimedia archive against the locked publisher manifest.
WIKTIONARY="$ARCHIVES/ukwiktionary-latest-pages-articles.xml.bz2"
EXPECTED_SHA1="$(awk '$2 ~ /-pages-articles.xml.bz2$/ { print $1; exit }' \
  "$METADATA/ukwiktionary-latest-sha1sums.txt")"
ACTUAL_SHA1="$(shasum -a 1 "$WIKTIONARY" | awk '{print $1}')"
[[ -n "$EXPECTED_SHA1" && "$EXPECTED_SHA1" == "$ACTUAL_SHA1" ]] || {
  echo "Wiktionary publisher SHA-1 verification failed." >&2
  exit 1
}

write_inventory
echo "Verified locked Ukrainian sources in: $DESTINATION"
