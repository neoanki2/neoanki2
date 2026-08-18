#!/usr/bin/env bash
set -euo pipefail

PR_NUMBER=""
INSTALL=0
FORCE_LAUNCH=0
TAP_REPOSITORY="neoanki2/homebrew-tap"
APP_PATH="/Applications/NeoAnki2.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/NeoAnki2"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/ship-release.sh --pr NUMBER [--install] [--launch]

Promotes the exact candidate for a tested pull request with safe resume support.
Completed merge, publication, tap, or installation phases are detected and skipped.

  --install  Upgrade the official Homebrew cask. NeoAnki2 is stopped only
             immediately before replacement and is relaunched once only if it
             was running beforehand.
  --launch   Also launch /Applications/NeoAnki2.app when it was initially closed.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR_NUMBER="${2:?--pr needs a number}"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --launch) FORCE_LAUNCH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "A numeric --pr value is required." >&2
  exit 2
fi
if [ "$FORCE_LAUNCH" -eq 1 ] && [ "$INSTALL" -ne 1 ]; then
  echo "--launch requires --install." >&2
  exit 2
fi

for command in gh git jq base64 ruby shasum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done
if [ "$INSTALL" -eq 1 ]; then
  for command in brew codesign osascript pgrep ps; do
    command -v "$command" >/dev/null 2>&1 || {
      echo "Missing required command for --install: $command" >&2
      exit 1
    }
  done
fi
gh auth status >/dev/null

REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

wait_for_required_checks() {
  local required_contexts_json checks_json context bucket missing pending
  required_contexts_json="$(gh api \
    "repos/$REPOSITORY/branches/$BASE_BRANCH/protection" \
    --jq '.required_status_checks.contexts')"
  if [ "$(jq 'length' <<<"$required_contexts_json")" -eq 0 ]; then
    echo "$BASE_BRANCH has no configured required status checks." >&2
    return 1
  fi

  while true; do
    checks_json="$(gh pr checks "$PR_NUMBER" --repo "$REPOSITORY" \
      --required --json name,bucket 2>/dev/null || true)"
    [ -n "$checks_json" ] || checks_json='[]'
    missing=0
    pending=0
    while IFS= read -r context; do
      bucket="$(jq -r --arg name "$context" \
        '[.[] | select(.name == $name)] | last | .bucket // "missing"' \
        <<<"$checks_json")"
      case "$bucket" in
        pass) ;;
        fail|cancel)
          echo "Required check failed: $context ($bucket)" >&2
          gh pr checks "$PR_NUMBER" --repo "$REPOSITORY" --required || true
          return 1
          ;;
        missing) missing=1 ;;
        *) pending=1 ;;
      esac
    done < <(jq -r '.[]' <<<"$required_contexts_json")

    if [ "$missing" -eq 0 ] && [ "$pending" -eq 0 ]; then
      echo "All required checks passed."
      return 0
    fi
    echo "Waiting for required checks (missing=$missing pending=$pending)..."
    sleep 10
  done
}

PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" \
  --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefOid,baseRefName,mergeCommit)"
PR_STATE="$(jq -r .state <<<"$PR_JSON")"
HEAD_SHA="$(jq -r .headRefOid <<<"$PR_JSON")"
BASE_SHA="$(jq -r .baseRefOid <<<"$PR_JSON")"
BASE_BRANCH="$(jq -r .baseRefName <<<"$PR_JSON")"

if [ "$PR_STATE" = "OPEN" ]; then
  if [ "$(jq -r .isDraft <<<"$PR_JSON")" != "false" ]; then
    echo "Pull request #$PR_NUMBER is still a draft." >&2
    exit 1
  fi
  echo "Confirming required checks for PR #$PR_NUMBER..."
  wait_for_required_checks
  PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" \
    --json state,mergeable,mergeStateStatus,headRefOid,baseRefOid,baseRefName,mergeCommit)"
  if [ "$(jq -r .mergeable <<<"$PR_JSON")" != "MERGEABLE" ] || \
     [ "$(jq -r .mergeStateStatus <<<"$PR_JSON")" != "CLEAN" ]; then
    echo "Pull request #$PR_NUMBER is not cleanly mergeable after checks passed." >&2
    exit 1
  fi
  REMOTE_BASE_SHA="$(gh api "repos/$REPOSITORY/git/ref/heads/$BASE_BRANCH" --jq .object.sha)"
  if [ "$BASE_SHA" != "$REMOTE_BASE_SHA" ]; then
    echo "PR #$PR_NUMBER is stale relative to $BASE_BRANCH." >&2
    exit 1
  fi
elif [ "$PR_STATE" != "MERGED" ]; then
  echo "Pull request #$PR_NUMBER is $PR_STATE; it cannot be promoted." >&2
  exit 1
fi

RELEASES_JSON="$(gh api --paginate "repos/$REPOSITORY/releases?per_page=100" | jq -s 'add')"
RELEASE_ID="$(jq -r --arg head "$HEAD_SHA" '
  [.[] | select(
    .target_commitish == $head and
    (.tag_name | test("^v1[.]0[.][0-9]+$")) and
    any(.assets[]?; .name == "release-candidate.json")
  )] | sort_by(.created_at) | last | .id // empty
' <<<"$RELEASES_JSON")"
if [ -z "$RELEASE_ID" ]; then
  echo "No release candidate targets PR #$PR_NUMBER head $HEAD_SHA." >&2
  echo "Run Scripts/release.sh --pr $PR_NUMBER to prepare or resume it." >&2
  exit 1
fi

RELEASE_API_JSON="$(gh api "repos/$REPOSITORY/releases/$RELEASE_ID")"
TAG="$(jq -r .tag_name <<<"$RELEASE_API_JSON")"
VERSION="${TAG#v}"

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
  '.schemaVersion == 1' \
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
if [[ ! "$CHECKSUM" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Candidate manifest contains an invalid SHA-256 checksum." >&2
  exit 1
fi
for required_asset in "$ARTIFACT" "$ARTIFACT.sha256" release-candidate.json; do
  jq -e --arg name "$required_asset" '.assets[] | select(.name == $name)' \
    <<<"$RELEASE_API_JSON" >/dev/null || {
      echo "Release candidate is missing $required_asset." >&2
      exit 1
    }
done

gh release download "$TAG" --repo "$REPOSITORY" \
  --pattern "$ARTIFACT.sha256" --dir "$PREFLIGHT_DIR"
if [ "$(awk '{print $1}' "$PREFLIGHT_DIR/$ARTIFACT.sha256")" != "$CHECKSUM" ]; then
  echo "Checksum asset disagrees with the candidate manifest." >&2
  exit 1
fi

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

echo "Candidate preflight passed for PR #$PR_NUMBER, $TAG, revision $HEAD_SHA."
STARTED_AT="$(date +%s)"

if [ "$PR_STATE" = "OPEN" ]; then
  gh pr merge "$PR_NUMBER" --repo "$REPOSITORY" --merge --delete-branch
  PR_STATE="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" --json state --jq .state)"
  if [ "$PR_STATE" != "MERGED" ]; then
    echo "Pull request #$PR_NUMBER did not reach the merged state." >&2
    exit 1
  fi
  echo "Merged PR #$PR_NUMBER."
else
  echo "PR #$PR_NUMBER is already merged; resuming promotion."
fi
MERGED_AT="$(date +%s)"

if [ "$(jq -r .draft <<<"$RELEASE_API_JSON")" = "true" ]; then
  gh api --method PATCH "repos/$REPOSITORY/releases/$RELEASE_ID" \
    -f tag_name="$TAG" \
    -f target_commitish="$HEAD_SHA" \
    -F draft=false \
    -f make_latest=true >/dev/null
  echo "Published $TAG."
else
  echo "$TAG is already published; resuming promotion."
fi
PUBLISHED_AT="$(date +%s)"

ENCODED_CASK="$(base64 < "$CASK_FILE" | tr -d '\n')"
UPDATED_TAP=0
for attempt in 1 2 3; do
  TAP_JSON="$(gh api "repos/$TAP_REPOSITORY/contents/Casks/neoanki2.rb?ref=main")"
  TAP_SHA="$(jq -r .sha <<<"$TAP_JSON")"
  CURRENT_CASK="$(jq -r .content <<<"$TAP_JSON" | base64 --decode)"
  if grep -Fq "version \"$VERSION\"" <<<"$CURRENT_CASK" && \
     grep -Fq "sha256 \"$CHECKSUM\"" <<<"$CURRENT_CASK"; then
    UPDATED_TAP=1
    echo "Homebrew tap already contains $VERSION with the candidate checksum."
    break
  fi
  if grep -Fq "version \"$VERSION\"" <<<"$CURRENT_CASK"; then
    echo "Homebrew tap already has $VERSION with a different checksum." >&2
    exit 1
  fi
  if gh api --method PUT "repos/$TAP_REPOSITORY/contents/Casks/neoanki2.rb" \
    -f message="Update NeoAnki2 to $VERSION" \
    -f content="$ENCODED_CASK" \
    -f sha="$TAP_SHA" \
    -f branch=main >/dev/null; then
    UPDATED_TAP=1
    echo "Updated the Homebrew tap to $VERSION."
    break
  fi
  echo "Tap changed concurrently; retrying ($attempt/3)." >&2
done
if [ "$UPDATED_TAP" -ne 1 ]; then
  echo "Unable to publish the Homebrew cask update." >&2
  exit 1
fi
TAP_UPDATED_AT="$(date +%s)"

if [ "$INSTALL" -eq 1 ]; then
  echo "Refreshing Homebrew while NeoAnki2 remains available..."
  TAP_DIRECTORY="$(brew --repository neoanki2/tap)"
  (cd "$TAP_DIRECTORY" && gh repo sync --branch main)
  TAP_VERSION="$(brew info --cask neoanki2/tap/neoanki2 --json=v2 | \
    jq -r '.casks[0].version')"
  if [ "$TAP_VERSION" != "$VERSION" ]; then
    echo "Homebrew resolved $TAP_VERSION; expected $VERSION." >&2
    exit 1
  fi

  APP_WAS_RUNNING=0
  if pgrep -x NeoAnki2 >/dev/null 2>&1; then
    APP_WAS_RUNNING=1
  fi
  stop_neoanki2() {
    /usr/bin/osascript -e 'tell application id "com.neoanki2.app" to quit' \
      >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      pgrep -x NeoAnki2 >/dev/null 2>&1 || return 0
      sleep 0.25
    done
    return 1
  }
  SHOULD_LAUNCH="$FORCE_LAUNCH"
  [ "$APP_WAS_RUNNING" -eq 1 ] && SHOULD_LAUNCH=1

  INSTALLED_MATCHES=0
  if [ -f "$APP_PATH/Contents/Info.plist" ]; then
    INSTALLED_VERSION="$(/usr/libexec/PlistBuddy \
      -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
    INSTALLED_REVISION="$(/usr/libexec/PlistBuddy \
      -c 'Print :NeoAnkiGitRevision' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$INSTALLED_VERSION" = "$VERSION" ] && [[ "$HEAD_SHA" == "$INSTALLED_REVISION"* ]] && \
       codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
      INSTALLED_MATCHES=1
    fi
  fi

  if [ "$INSTALLED_MATCHES" -eq 1 ] && [ "$APP_WAS_RUNNING" -eq 1 ]; then
    PROCESS_PATHS_MATCH=1
    while IFS= read -r pid; do
      PROCESS_COMMAND="$(ps -p "$pid" -o command=)"
      if [[ "$PROCESS_COMMAND" != "$APP_EXECUTABLE"* ]]; then
        PROCESS_PATHS_MATCH=0
      fi
    done < <(pgrep -x NeoAnki2)
    if [ "$PROCESS_PATHS_MATCH" -ne 1 ]; then
      echo "Stopping a non-installed NeoAnki2 process before correcting its launch path..."
      if ! stop_neoanki2; then
        echo "NeoAnki2 did not stop cleanly; refusing to relaunch it." >&2
        exit 1
      fi
    fi
  fi

  if [ "$INSTALLED_MATCHES" -ne 1 ]; then
    if [ "$APP_WAS_RUNNING" -eq 1 ]; then
      echo "Stopping NeoAnki2 immediately before Homebrew replaces the app..."
      if ! stop_neoanki2; then
        echo "NeoAnki2 did not stop cleanly; refusing to replace it." >&2
        exit 1
      fi
    fi

    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
      brew upgrade --cask neoanki2/tap/neoanki2 --no-quit --require-sha -y
  else
    echo "$APP_PATH already contains the verified $VERSION build."
  fi

  INSTALLED_VERSION="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
  INSTALLED_REVISION="$(/usr/libexec/PlistBuddy \
    -c 'Print :NeoAnkiGitRevision' "$APP_PATH/Contents/Info.plist")"
  if [ "$INSTALLED_VERSION" != "$VERSION" ] || [[ "$HEAD_SHA" != "$INSTALLED_REVISION"* ]]; then
    echo "Installed app metadata does not match $VERSION at $HEAD_SHA." >&2
    exit 1
  fi
  codesign --verify --deep --strict "$APP_PATH"

  INSTALLED_PROCESS_RUNNING=0
  if pgrep -x NeoAnki2 >/dev/null 2>&1; then
    while IFS= read -r pid; do
      PROCESS_COMMAND="$(ps -p "$pid" -o command=)"
      if [[ "$PROCESS_COMMAND" == "$APP_EXECUTABLE"* ]]; then
        INSTALLED_PROCESS_RUNNING=1
      else
        echo "A NeoAnki2 process is running from an unexpected path: $PROCESS_COMMAND" >&2
        exit 1
      fi
    done < <(pgrep -x NeoAnki2)
  fi

  if [ "$SHOULD_LAUNCH" -eq 1 ] && [ "$INSTALLED_PROCESS_RUNNING" -ne 1 ]; then
    echo "Launching the installed app once from its absolute path..."
    /usr/bin/open "$APP_PATH"
    for _ in $(seq 1 40); do
      if pgrep -x NeoAnki2 >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
    LAUNCHED_PATH_OK=0
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      PROCESS_COMMAND="$(ps -p "$pid" -o command=)"
      if [[ "$PROCESS_COMMAND" == "$APP_EXECUTABLE"* ]]; then
        LAUNCHED_PATH_OK=1
      fi
    done < <(pgrep -x NeoAnki2 2>/dev/null || true)
    if [ "$LAUNCHED_PATH_OK" -ne 1 ]; then
      echo "The single launch attempt did not start $APP_EXECUTABLE." >&2
      exit 1
    fi
    echo "Verified the running executable: $APP_EXECUTABLE"
  elif [ "$INSTALLED_PROCESS_RUNNING" -eq 1 ]; then
    echo "The verified installed app is already running."
  fi
fi

FINISHED_AT="$(date +%s)"
echo "SHIP_PR=$PR_NUMBER"
echo "SHIP_RELEASE=$TAG"
echo "SHIP_REVISION=$HEAD_SHA"
echo "SHIP_MERGE_SECONDS=$((MERGED_AT - STARTED_AT))"
echo "SHIP_PUBLISH_SECONDS=$((PUBLISHED_AT - MERGED_AT))"
echo "SHIP_TAP_SECONDS=$((TAP_UPDATED_AT - PUBLISHED_AT))"
echo "SHIP_ELAPSED_SECONDS=$((FINISHED_AT - STARTED_AT))"
