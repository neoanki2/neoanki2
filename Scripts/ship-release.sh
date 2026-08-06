#!/usr/bin/env bash
set -euo pipefail

PR_NUMBER=""
INSTALL=0
MAX_SECONDS=50
TAP_REPOSITORY="neoanki2/homebrew-tap"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/ship-release.sh --pr NUMBER [--install] [--max-seconds N]

Promotes an already-tested draft candidate. The measured hot path starts just
before the merge-to-main operation and includes release publication, direct tap
update, and (with --install) a headless Homebrew upgrade.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR_NUMBER="${2:?--pr needs a number}"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --max-seconds) MAX_SECONDS="${2:?--max-seconds needs a number}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "A numeric --pr value is required." >&2
  exit 2
fi
if [[ ! "$MAX_SECONDS" =~ ^[0-9]+$ ]] || [ "$MAX_SECONDS" -lt 1 ]; then
  echo "--max-seconds must be a positive integer." >&2
  exit 2
fi

for command in gh git jq base64; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done
if [ "$INSTALL" -eq 1 ]; then
  command -v brew >/dev/null 2>&1 || {
    echo "Homebrew is required for --install." >&2
    exit 1
  }
  if pgrep -x NeoAnki2 >/dev/null 2>&1; then
    echo "NeoAnki2 is running. Quit it before shipping; this command will not touch the desktop." >&2
    exit 1
  fi
fi

REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" \
  --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefOid,baseRefName)"
if [ "$(jq -r .state <<<"$PR_JSON")" != "OPEN" ]; then
  echo "Pull request #$PR_NUMBER is not open." >&2
  exit 1
fi
if [ "$(jq -r .isDraft <<<"$PR_JSON")" != "false" ]; then
  echo "Pull request #$PR_NUMBER is still a draft." >&2
  exit 1
fi
if [ "$(jq -r .mergeable <<<"$PR_JSON")" != "MERGEABLE" ] || \
   [ "$(jq -r .mergeStateStatus <<<"$PR_JSON")" != "CLEAN" ]; then
  echo "Pull request #$PR_NUMBER is not cleanly mergeable." >&2
  exit 1
fi

HEAD_SHA="$(jq -r .headRefOid <<<"$PR_JSON")"
BASE_SHA="$(jq -r .baseRefOid <<<"$PR_JSON")"
BASE_BRANCH="$(jq -r .baseRefName <<<"$PR_JSON")"
REMOTE_BASE_SHA="$(gh api "repos/$REPOSITORY/git/ref/heads/$BASE_BRANCH" --jq .object.sha)"
if [ "$BASE_SHA" != "$REMOTE_BASE_SHA" ]; then
  echo "PR #$PR_NUMBER is stale relative to $BASE_BRANCH." >&2
  exit 1
fi

LATEST_TAG="$(gh release view --repo "$REPOSITORY" --json tagName --jq .tagName)"
if [[ ! "$LATEST_TAG" =~ ^v1[.]0[.]([0-9]+)$ ]]; then
  echo "Latest release tag has an unsupported format: $LATEST_TAG" >&2
  exit 1
fi
VERSION="1.0.$((BASH_REMATCH[1] + 1))"
TAG="v$VERSION"
RELEASE_JSON="$(gh release view "$TAG" --repo "$REPOSITORY" \
  --json databaseId,isDraft,targetCommitish,assets)"
if [ "$(jq -r .isDraft <<<"$RELEASE_JSON")" != "true" ]; then
  echo "Release candidate $TAG is not a draft." >&2
  exit 1
fi
if [ "$(jq -r .targetCommitish <<<"$RELEASE_JSON")" != "$HEAD_SHA" ]; then
  echo "Release candidate $TAG does not target PR #$PR_NUMBER head $HEAD_SHA." >&2
  exit 1
fi

PREFLIGHT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/neoanki2-ship-preflight.XXXXXX")"
CASK_FILE="$(mktemp "${TMPDIR:-/tmp}/neoanki2-cask.XXXXXX")"
cleanup() {
  rm -rf "$PREFLIGHT_DIR"
  rm -f "$CASK_FILE"
}
trap cleanup EXIT

gh release download "$TAG" --repo "$REPOSITORY" \
  --pattern release-candidate.json --dir "$PREFLIGHT_DIR"
MANIFEST="$PREFLIGHT_DIR/release-candidate.json"
for assertion in \
  ".pullRequest == $PR_NUMBER" \
  ".headSha == \"$HEAD_SHA\"" \
  ".baseSha == \"$BASE_SHA\"" \
  ".version == \"$VERSION\"" \
  ".tag == \"$TAG\""; do
  jq -e "$assertion" "$MANIFEST" >/dev/null || {
    echo "Candidate manifest failed assertion: $assertion" >&2
    exit 1
  }
done
ARTIFACT="$(jq -r .artifact "$MANIFEST")"
CHECKSUM="$(jq -r .checksum "$MANIFEST")"
for required_asset in "$ARTIFACT" "$ARTIFACT.sha256" release-candidate.json; do
  jq -e --arg name "$required_asset" '.assets[] | select(.name == $name)' \
    <<<"$RELEASE_JSON" >/dev/null || {
      echo "Draft release is missing $required_asset." >&2
      exit 1
    }
done

cat > "$CASK_FILE" <<EOF
cask "neoanki2" do
  version "$VERSION"
  sha256 "$CHECKSUM"

  url "https://github.com/neoanki2/neoanki2/releases/download/v#{version}/NeoAnki2-#{version}-mac-universal.dmg"
  name "NeoAnki2"
  desc "Native, local-first spaced-repetition app with FSRS scheduling"
  homepage "https://neoanki2.github.io/"

  depends_on macos: :sonoma

  app "NeoAnki2.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/NeoAnki2.app"]
  end

  caveats <<~EOS
    NeoAnki2 is currently ad-hoc signed and is not Apple-notarized. This cask
    removes its quarantine attribute after installation so it can launch normally.
  EOS
end
EOF
ruby -c "$CASK_FILE" >/dev/null

echo "Preflight passed for PR #$PR_NUMBER, candidate $TAG, revision $HEAD_SHA"
STARTED_AT="$(date +%s)"

gh pr merge "$PR_NUMBER" --repo "$REPOSITORY" --merge --delete-branch
MERGED_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" \
  --json state,mergeCommit)"
if [ "$(jq -r .state <<<"$MERGED_JSON")" != "MERGED" ]; then
  echo "Pull request #$PR_NUMBER did not reach the merged state." >&2
  exit 1
fi

RELEASE_ID="$(jq -r .databaseId <<<"$RELEASE_JSON")"
gh api --method PATCH "repos/$REPOSITORY/releases/$RELEASE_ID" \
  -F draft=false -f make_latest=true >/dev/null

ENCODED_CASK="$(base64 < "$CASK_FILE" | tr -d '\n')"
UPDATED_TAP=0
for attempt in 1 2; do
  TAP_JSON="$(gh api "repos/$TAP_REPOSITORY/contents/Casks/neoanki2.rb?ref=main")"
  TAP_SHA="$(jq -r .sha <<<"$TAP_JSON")"
  CURRENT_CASK="$(jq -r .content <<<"$TAP_JSON" | base64 --decode)"
  if grep -Fq "version \"$VERSION\"" <<<"$CURRENT_CASK"; then
    UPDATED_TAP=1
    break
  fi
  if gh api --method PUT "repos/$TAP_REPOSITORY/contents/Casks/neoanki2.rb" \
    -f message="Update NeoAnki2 to $VERSION" \
    -f content="$ENCODED_CASK" \
    -f sha="$TAP_SHA" \
    -f branch=main >/dev/null; then
    UPDATED_TAP=1
    break
  fi
  echo "Tap changed concurrently; retrying ($attempt/2)." >&2
done
if [ "$UPDATED_TAP" -ne 1 ]; then
  echo "Unable to publish the Homebrew cask update." >&2
  exit 1
fi

if [ "$INSTALL" -eq 1 ]; then
  brew update --quiet
  TAP_VERSION="$(brew info --cask neoanki2/tap/neoanki2 --json=v2 | \
    jq -r '.casks[0].version')"
  if [ "$TAP_VERSION" != "$VERSION" ]; then
    echo "Homebrew resolved $TAP_VERSION after the tap update; expected $VERSION." >&2
    exit 1
  fi
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
    brew upgrade --cask neoanki2/tap/neoanki2 --no-quit --require-sha -y

  INSTALLED_VERSION="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    /Applications/NeoAnki2.app/Contents/Info.plist)"
  if [ "$INSTALLED_VERSION" != "$VERSION" ]; then
    echo "Installed app version is $INSTALLED_VERSION; expected $VERSION." >&2
    exit 1
  fi
  codesign --verify --deep --strict /Applications/NeoAnki2.app
  if pgrep -x NeoAnki2 >/dev/null 2>&1; then
    echo "NeoAnki2 unexpectedly launched during installation." >&2
    exit 1
  fi
fi

FINISHED_AT="$(date +%s)"
ELAPSED_SECONDS="$((FINISHED_AT - STARTED_AT))"
echo "SHIP_RELEASE=$TAG"
echo "SHIP_REVISION=$HEAD_SHA"
echo "SHIP_ELAPSED_SECONDS=$ELAPSED_SECONDS"

if [ "$ELAPSED_SECONDS" -ge "$MAX_SECONDS" ]; then
  echo "Shipping took ${ELAPSED_SECONDS}s, exceeding the ${MAX_SECONDS}s target." >&2
  exit 3
fi
