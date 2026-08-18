#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PR_NUMBER=""
OUTPUT_DIR="$ROOT/.build/release-candidate"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/build-release-candidate.sh --pr NUMBER [--output DIR]

Builds a versioned universal DMG and a manifest tied to the exact pull-request
head and base revisions. Publishing the draft release is a separate step so
tests and packaging can run in parallel in CI.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR_NUMBER="${2:?--pr needs a number}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:?--output needs a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "A numeric --pr value is required." >&2
  exit 2
fi

for command in gh git jq shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" \
  --json state,headRefOid,baseRefOid,baseRefName)"
STATE="$(jq -r .state <<<"$PR_JSON")"
HEAD_SHA="$(jq -r .headRefOid <<<"$PR_JSON")"
BASE_SHA="$(jq -r .baseRefOid <<<"$PR_JSON")"
BASE_BRANCH="$(jq -r .baseRefName <<<"$PR_JSON")"
CHECKED_OUT_SHA="$(git -C "$ROOT" rev-parse HEAD)"

if [ "$STATE" != "OPEN" ]; then
  echo "Pull request #$PR_NUMBER is not open." >&2
  exit 1
fi
if [ "$CHECKED_OUT_SHA" != "$HEAD_SHA" ]; then
  echo "Checked-out revision $CHECKED_OUT_SHA is not PR #$PR_NUMBER head $HEAD_SHA." >&2
  exit 1
fi
if ! git -C "$ROOT" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA"; then
  echo "PR #$PR_NUMBER is not based on the current $BASE_BRANCH revision." >&2
  exit 1
fi

LATEST_TAG="$(gh release view --repo "$REPOSITORY" --json tagName --jq .tagName)"
if [[ ! "$LATEST_TAG" =~ ^v1[.]0[.]([0-9]+)$ ]]; then
  echo "Latest release tag has an unsupported format: $LATEST_TAG" >&2
  exit 1
fi
BUILD_NUMBER="$((BASH_REMATCH[1] + 1))"
VERSION="1.0.$BUILD_NUMBER"
TAG="v$VERSION"
ARTIFACT="NeoAnki2-$VERSION-mac-universal.dmg"
TREE_SHA="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"

if RELEASE_JSON="$(gh release view "$TAG" --repo "$REPOSITORY" \
  --json isDraft,targetCommitish 2>/dev/null)"; then
  if [ "$(jq -r .isDraft <<<"$RELEASE_JSON")" != "true" ]; then
    echo "Release $TAG already exists and is published." >&2
    exit 1
  fi
  if [ "$(jq -r .targetCommitish <<<"$RELEASE_JSON")" != "$HEAD_SHA" ]; then
    echo "Draft $TAG already belongs to another source revision." >&2
    exit 1
  fi
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

NEOANKI_RELEASE_BUILD_NUMBER="$BUILD_NUMBER" \
NEOANKI_RELEASE_VERSION="$VERSION" \
  "$ROOT/Scripts/build-release-artifact.sh" "$OUTPUT_DIR"

CHECKSUM="$(shasum -a 256 "$OUTPUT_DIR/$ARTIFACT" | awk '{print $1}')"
EXPECTED_CHECKSUM="$(awk '{print $1}' "$OUTPUT_DIR/$ARTIFACT.sha256")"
if [ "$CHECKSUM" != "$EXPECTED_CHECKSUM" ]; then
  echo "Generated checksum does not match the release artifact." >&2
  exit 1
fi

jq -n \
  --arg repository "$REPOSITORY" \
  --argjson pullRequest "$PR_NUMBER" \
  --arg headSha "$HEAD_SHA" \
  --arg baseSha "$BASE_SHA" \
  --arg baseBranch "$BASE_BRANCH" \
  --arg treeSha "$TREE_SHA" \
  --arg version "$VERSION" \
  --arg tag "$TAG" \
  --argjson buildNumber "$BUILD_NUMBER" \
  --arg artifact "$ARTIFACT" \
  --arg checksum "$CHECKSUM" \
  --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    schemaVersion: 1,
    repository: $repository,
    pullRequest: $pullRequest,
    headSha: $headSha,
    baseSha: $baseSha,
    baseBranch: $baseBranch,
    treeSha: $treeSha,
    version: $version,
    tag: $tag,
    buildNumber: $buildNumber,
    artifact: $artifact,
    checksum: $checksum,
    createdAt: $createdAt
  }' > "$OUTPUT_DIR/release-candidate.json"

echo "Prepared release candidate $TAG for PR #$PR_NUMBER at $HEAD_SHA"
echo "Candidate directory: $OUTPUT_DIR"
