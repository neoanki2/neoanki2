#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT/.build/local-release-candidate"
BASE_BRANCH="main"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/prepare-local-release.sh [--base BRANCH] [--output DIR]

Runs headless validation, builds the universal release locally, and uploads a
draft release before the branch's first push. The draft temporarily targets the
current base revision; the timed shipping command retargets it after pushing.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_BRANCH="${2:?--base needs a branch}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:?--output needs a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

for command in gh git jq shasum swift; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
BRANCH="$(git -C "$ROOT" branch --show-current)"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
BASE_SHA="$(gh api "repos/$REPOSITORY/git/ref/heads/$BASE_BRANCH" --jq .object.sha)"
TREE_SHA="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"

if [ -z "$BRANCH" ] || [ "$BRANCH" = "$BASE_BRANCH" ]; then
  echo "Prepare a local release from an unpushed feature branch." >&2
  exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain=v1)" ]; then
  echo "The worktree must be clean before preparing a release." >&2
  exit 1
fi
if ! git -C "$ROOT" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA"; then
  echo "$BRANCH is not based on the current $BASE_BRANCH revision." >&2
  exit 1
fi
if gh api "repos/$REPOSITORY/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  echo "Remote branch $BRANCH already exists; the push timer would be invalid." >&2
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

echo "Running headless pre-push validation..."
(cd "$ROOT" && swift test --parallel)
(cd "$ROOT/NeoAnkiCore" && swift test --parallel)
(cd "$ROOT" && swift Scripts/validate-docs.swift --require-screenshots --base-ref origin/main)
bash -n "$ROOT/Scripts/build-release-candidate.sh" \
  "$ROOT/Scripts/publish-release-candidate.sh" \
  "$ROOT/Scripts/ship-release.sh" \
  "$ROOT/Scripts/prepare-local-release.sh" \
  "$ROOT/Scripts/push-ship-release.sh"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
NEOANKI_RELEASE_BUILD_NUMBER="$BUILD_NUMBER" \
NEOANKI_RELEASE_VERSION="$VERSION" \
  "$ROOT/Scripts/build-release-artifact.sh" "$OUTPUT_DIR"

CHECKSUM="$(shasum -a 256 "$OUTPUT_DIR/$ARTIFACT" | awk '{print $1}')"
if [ "$CHECKSUM" != "$(awk '{print $1}' "$OUTPUT_DIR/$ARTIFACT.sha256")" ]; then
  echo "Generated checksum does not match the release artifact." >&2
  exit 1
fi

jq -n \
  --arg repository "$REPOSITORY" \
  --arg mode local-prepush \
  --arg branch "$BRANCH" \
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
    mode: $mode,
    branch: $branch,
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

if EXISTING="$(gh release view "$TAG" --repo "$REPOSITORY" \
  --json isDraft 2>/dev/null)"; then
  if [ "$(jq -r .isDraft <<<"$EXISTING")" != "true" ]; then
    echo "Published release $TAG already exists." >&2
    exit 1
  fi
  gh release delete "$TAG" --repo "$REPOSITORY" --yes
fi

NOTES_FILE="$OUTPUT_DIR/release-notes.md"
cat > "$NOTES_FILE" <<EOF
Locally prepared release candidate for branch \`$BRANCH\`.

- Exact source revision: \`$HEAD_SHA\`
- Base revision: \`$BASE_SHA\`
- Version: \`$VERSION\`
- Validation and universal compilation completed before the timed push.
EOF

gh release create "$TAG" \
  "$OUTPUT_DIR/$ARTIFACT" \
  "$OUTPUT_DIR/$ARTIFACT.sha256" \
  "$OUTPUT_DIR/release-candidate.json" \
  --repo "$REPOSITORY" \
  --draft \
  --target "$BASE_SHA" \
  --title "NeoAnki2 $VERSION" \
  --notes-file "$NOTES_FILE"

echo "LOCAL_CANDIDATE_TAG=$TAG"
echo "LOCAL_CANDIDATE_REVISION=$HEAD_SHA"
echo "LOCAL_CANDIDATE_DIR=$OUTPUT_DIR"
