#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE_DIR="$ROOT/.build/local-release-candidate"
TITLE=""
BODY_FILE=""
INSTALL=0
MAX_SECONDS=60
TAP_REPOSITORY="neoanki2/homebrew-tap"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/push-ship-release.sh --title TITLE --body-file FILE [options]

Options:
  --candidate DIR   Prepared candidate directory
  --install         Upgrade the installed Homebrew cask without launching it
  --max-seconds N   Strict elapsed-time ceiling (default: 60)

The timer starts immediately before the branch's first push and includes PR
creation, merge, publication, tap update, and optional Homebrew installation.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) CANDIDATE_DIR="${2:?--candidate needs a directory}"; shift 2 ;;
    --title) TITLE="${2:?--title needs text}"; shift 2 ;;
    --body-file) BODY_FILE="${2:?--body-file needs a file}"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --max-seconds) MAX_SECONDS="${2:?--max-seconds needs a number}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$TITLE" ] || [ ! -f "$BODY_FILE" ]; then
  echo "--title and an existing --body-file are required." >&2
  exit 2
fi
if [[ ! "$MAX_SECONDS" =~ ^[0-9]+$ ]] || [ "$MAX_SECONDS" -lt 1 ]; then
  echo "--max-seconds must be a positive integer." >&2
  exit 2
fi

for command in gh git jq base64 ruby; do
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
    echo "NeoAnki2 is running. Quit it first; this command will not touch the desktop." >&2
    exit 1
  fi
fi

MANIFEST="$CANDIDATE_DIR/release-candidate.json"
if [ ! -f "$MANIFEST" ]; then
  echo "Prepared candidate manifest is missing: $MANIFEST" >&2
  exit 1
fi

REPOSITORY="$(jq -r .repository "$MANIFEST")"
BRANCH="$(jq -r .branch "$MANIFEST")"
HEAD_SHA="$(jq -r .headSha "$MANIFEST")"
BASE_SHA="$(jq -r .baseSha "$MANIFEST")"
BASE_BRANCH="$(jq -r .baseBranch "$MANIFEST")"
VERSION="$(jq -r .version "$MANIFEST")"
TAG="$(jq -r .tag "$MANIFEST")"
ARTIFACT="$(jq -r .artifact "$MANIFEST")"
CHECKSUM="$(jq -r .checksum "$MANIFEST")"

if [ "$(git -C "$ROOT" branch --show-current)" != "$BRANCH" ] || \
   [ "$(git -C "$ROOT" rev-parse HEAD)" != "$HEAD_SHA" ]; then
  echo "The checked-out branch no longer matches the prepared candidate." >&2
  exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain=v1)" ]; then
  echo "The worktree must be clean before shipping." >&2
  exit 1
fi
if [ "$(gh api "repos/$REPOSITORY/git/ref/heads/$BASE_BRANCH" --jq .object.sha)" != "$BASE_SHA" ]; then
  echo "$BASE_BRANCH changed after candidate preparation." >&2
  exit 1
fi
if gh api "repos/$REPOSITORY/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  echo "Remote branch $BRANCH already exists; refusing to report a false push timing." >&2
  exit 1
fi

RELEASE_JSON="$(gh release view "$TAG" --repo "$REPOSITORY" \
  --json databaseId,isDraft,targetCommitish,assets)"
if [ "$(jq -r .isDraft <<<"$RELEASE_JSON")" != "true" ] || \
   [ "$(jq -r .targetCommitish <<<"$RELEASE_JSON")" != "$BASE_SHA" ]; then
  echo "Draft release $TAG is not the prepared pre-push candidate." >&2
  exit 1
fi
for required_asset in "$ARTIFACT" "$ARTIFACT.sha256" release-candidate.json; do
  jq -e --arg name "$required_asset" '.assets[] | select(.name == $name)' \
    <<<"$RELEASE_JSON" >/dev/null || {
      echo "Draft release is missing $required_asset." >&2
      exit 1
    }
done

CASK_FILE="$(mktemp "${TMPDIR:-/tmp}/neoanki2-cask.XXXXXX")"
cleanup() {
  rm -f "$CASK_FILE"
}
trap cleanup EXIT
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

if [ "$INSTALL" -eq 1 ]; then
  TAP_DIRECTORY="$(brew --repository neoanki2/tap)"
  echo "Refreshing only neoanki2/tap before the measured push..."
  (cd "$TAP_DIRECTORY" && gh repo sync --branch main)
fi

echo "Preflight passed. Starting push-to-installed timer for $TAG."
STARTED_AT="$(date +%s)"

git -C "$ROOT" push --set-upstream origin "$BRANCH"
PUSHED_AT="$(date +%s)"

RELEASE_ID="$(jq -r .databaseId <<<"$RELEASE_JSON")"
gh api --method PATCH "repos/$REPOSITORY/releases/$RELEASE_ID" \
  -f target_commitish="$HEAD_SHA" >/dev/null

PR_URL="$(gh pr create --repo "$REPOSITORY" --base "$BASE_BRANCH" \
  --head "$BRANCH" --title "$TITLE" --body-file "$BODY_FILE")"
PR_NUMBER="$(gh pr view "$PR_URL" --repo "$REPOSITORY" --json number --jq .number)"
PR_CREATED_AT="$(date +%s)"

gh pr merge "$PR_NUMBER" --repo "$REPOSITORY" --merge --delete-branch
if [ "$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" --json state --jq .state)" != "MERGED" ]; then
  echo "Pull request #$PR_NUMBER did not reach the merged state." >&2
  exit 1
fi
MERGED_AT="$(date +%s)"

gh api --method PATCH "repos/$REPOSITORY/releases/$RELEASE_ID" \
  -F draft=false -f make_latest=true >/dev/null
PUBLISHED_AT="$(date +%s)"

ENCODED_CASK="$(base64 < "$CASK_FILE" | tr -d '\n')"
UPDATED_TAP=0
for attempt in 1 2; do
  TAP_JSON="$(gh api "repos/$TAP_REPOSITORY/contents/Casks/neoanki2.rb?ref=main")"
  TAP_SHA="$(jq -r .sha <<<"$TAP_JSON")"
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
TAP_UPDATED_AT="$(date +%s)"
BREW_UPDATED_AT="$TAP_UPDATED_AT"

if [ "$INSTALL" -eq 1 ]; then
  (cd "$TAP_DIRECTORY" && gh repo sync --branch main)
  BREW_UPDATED_AT="$(date +%s)"
  if [ "$(brew info --cask neoanki2/tap/neoanki2 --json=v2 | jq -r '.casks[0].version')" != "$VERSION" ]; then
    echo "Homebrew did not resolve the newly committed tap version." >&2
    exit 1
  fi
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
    brew upgrade --cask neoanki2/tap/neoanki2 --no-quit --require-sha -y

  INSTALLED_VERSION="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    /Applications/NeoAnki2.app/Contents/Info.plist)"
  INSTALLED_REVISION="$(/usr/libexec/PlistBuddy \
    -c 'Print :NeoAnkiGitRevision' \
    /Applications/NeoAnki2.app/Contents/Info.plist)"
  if [ "$INSTALLED_VERSION" != "$VERSION" ] || \
     [[ "$HEAD_SHA" != "$INSTALLED_REVISION"* ]]; then
    echo "Installed app metadata does not match $VERSION at $HEAD_SHA." >&2
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
echo "SHIP_PR=$PR_URL"
echo "SHIP_RELEASE=$TAG"
echo "SHIP_REVISION=$HEAD_SHA"
echo "SHIP_PUSH_SECONDS=$((PUSHED_AT - STARTED_AT))"
echo "SHIP_PR_SECONDS=$((PR_CREATED_AT - PUSHED_AT))"
echo "SHIP_MERGE_SECONDS=$((MERGED_AT - PR_CREATED_AT))"
echo "SHIP_PUBLISH_SECONDS=$((PUBLISHED_AT - MERGED_AT))"
echo "SHIP_TAP_SECONDS=$((TAP_UPDATED_AT - PUBLISHED_AT))"
echo "SHIP_BREW_REFRESH_SECONDS=$((BREW_UPDATED_AT - TAP_UPDATED_AT))"
echo "SHIP_INSTALL_SECONDS=$((FINISHED_AT - BREW_UPDATED_AT))"
echo "SHIP_ELAPSED_SECONDS=$ELAPSED_SECONDS"

if [ "$ELAPSED_SECONDS" -ge "$MAX_SECONDS" ]; then
  echo "Shipping took ${ELAPSED_SECONDS}s, exceeding the strict ${MAX_SECONDS}s ceiling." >&2
  exit 3
fi
