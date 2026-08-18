#!/usr/bin/env bash
set -euo pipefail

CANDIDATE_DIR="${1:-}"
if [ -z "$CANDIDATE_DIR" ] || [ ! -d "$CANDIDATE_DIR" ]; then
  echo "Usage: Scripts/publish-release-candidate.sh CANDIDATE_DIR" >&2
  exit 2
fi

for command in gh jq shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

MANIFEST="$CANDIDATE_DIR/release-candidate.json"
if [ ! -f "$MANIFEST" ]; then
  echo "Candidate manifest is missing: $MANIFEST" >&2
  exit 1
fi

REPOSITORY="$(jq -r .repository "$MANIFEST")"
PR_NUMBER="$(jq -r .pullRequest "$MANIFEST")"
HEAD_SHA="$(jq -r .headSha "$MANIFEST")"
VERSION="$(jq -r .version "$MANIFEST")"
TAG="$(jq -r .tag "$MANIFEST")"
ARTIFACT="$(jq -r .artifact "$MANIFEST")"
CHECKSUM="$(jq -r .checksum "$MANIFEST")"

if [ "$(shasum -a 256 "$CANDIDATE_DIR/$ARTIFACT" | awk '{print $1}')" != "$CHECKSUM" ]; then
  echo "Candidate artifact checksum does not match its manifest." >&2
  exit 1
fi
(cd "$CANDIDATE_DIR" && shasum -a 256 -c "$ARTIFACT.sha256")

if EXISTING="$(gh release view "$TAG" --repo "$REPOSITORY" \
  --json isDraft,targetCommitish 2>/dev/null)"; then
  if [ "$(jq -r .isDraft <<<"$EXISTING")" != "true" ]; then
    echo "Published release $TAG already exists." >&2
    exit 1
  fi
  if [ "$(jq -r .targetCommitish <<<"$EXISTING")" != "$HEAD_SHA" ]; then
    echo "Draft $TAG already belongs to another source revision." >&2
    exit 1
  fi
  gh release delete "$TAG" --repo "$REPOSITORY" --yes
fi

NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/neoanki2-candidate-notes.XXXXXX")"
cleanup() {
  rm -f "$NOTES_FILE"
}
trap cleanup EXIT

cat > "$NOTES_FILE" <<EOF
Prepared release candidate for PR #$PR_NUMBER.

- Exact source revision: \`$HEAD_SHA\`
- Version: \`$VERSION\`
- Publication is allowed only after this revision is merged unchanged into \`main\`.
EOF

gh release create "$TAG" \
  "$CANDIDATE_DIR/$ARTIFACT" \
  "$CANDIDATE_DIR/$ARTIFACT.sha256" \
  "$MANIFEST" \
  --repo "$REPOSITORY" \
  --draft \
  --target "$HEAD_SHA" \
  --title "NeoAnki2 $VERSION" \
  --notes-file "$NOTES_FILE"

echo "Published draft release candidate $TAG for PR #$PR_NUMBER"
