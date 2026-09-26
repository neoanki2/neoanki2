#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_BRANCH="main"
TITLE=""
INSTALL=1
LAUNCH=1
SLO_SECONDS="${NEOANKI_RELEASE_SLO_SECONDS:-300}"
STARTED_AT="$(date +%s)"
PHASE="arguments"
BUILD_SECONDS=0
TEST_SECONDS=0
REMOTE_SECONDS=0
INSTALL_SECONDS=0
BUILD_PID=""
TEST_PID=""
WORK_DIR=""

report() {
  local status="$1"
  local finished_at elapsed
  finished_at="$(date +%s)"
  elapsed="$((finished_at - STARTED_AT))"
  trap - EXIT
  echo "FAST_RELEASE_STATUS=$([ "$status" -eq 0 ] && echo success || echo failure)"
  echo "FAST_RELEASE_PHASE=$PHASE"
  echo "FAST_RELEASE_BUILD_SECONDS=$BUILD_SECONDS"
  echo "FAST_RELEASE_TEST_SECONDS=$TEST_SECONDS"
  echo "FAST_RELEASE_REMOTE_SECONDS=$REMOTE_SECONDS"
  echo "FAST_RELEASE_INSTALL_SECONDS=$INSTALL_SECONDS"
  echo "FAST_RELEASE_SLO_SECONDS=$SLO_SECONDS"
  echo "FAST_RELEASE_SLO_MET=$([ "$status" -eq 0 ] && [ "$elapsed" -le "$SLO_SECONDS" ] && echo true || echo false)"
  echo "FAST_RELEASE_ELAPSED_SECONDS=$elapsed"
}

cleanup() {
  [ -z "$BUILD_PID" ] || kill "$BUILD_PID" >/dev/null 2>&1 || true
  [ -z "$TEST_PID" ] || kill "$TEST_PID" >/dev/null 2>&1 || true
  if [ -n "$WORK_DIR" ] && [[ "$WORK_DIR" == "${TMPDIR:-/tmp}"/neoanki2-fast-release.* ]]; then
    rm -rf "$WORK_DIR"
  fi
}

on_exit() {
  local status="$?"
  trap - EXIT
  cleanup
  report "$status"
  exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/release-fast.sh [options]

Takes the current local changes all the way to the installed Homebrew app.
The command commits the exact working tree, runs the fast headless suite and
universal artifact build concurrently, creates and administratively merges a
PR, publishes the artifact, updates the official tap, and installs it.

Options:
  --title TEXT      Commit, PR, and release summary (automatic by default)
  --base BRANCH     Pull-request base branch (default: main)
  --no-install      Publish and update the tap without upgrading this Mac
  --no-launch       Install but leave NeoAnki2 closed when it began closed
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE="${2:?--title needs text}"; shift 2 ;;
    --base) BASE_BRANCH="${2:?--base needs a branch}"; shift 2 ;;
    --no-install) INSTALL=0; LAUNCH=0; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! "$SLO_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "NEOANKI_RELEASE_SLO_SECONDS must be a positive integer." >&2
  exit 2
fi

for command in base64 brew codesign gh git jq pgrep ps ruby shasum swift; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done
gh auth status >/dev/null

remaining_seconds() {
  echo "$((SLO_SECONDS - ($(date +%s) - STARTED_AT)))"
}

require_budget() {
  local required="$1"
  local operation="$2"
  local remaining
  remaining="$(remaining_seconds)"
  if [ "$remaining" -lt "$required" ]; then
    echo "Only ${remaining}s remain; ${operation} needs a ${required}s safety budget." >&2
    echo "Nothing after the last completed phase will be started." >&2
    return 1
  fi
}

push_branch() {
  local repository="$1"
  local branch="$2"
  git -C "$ROOT" \
    -c credential.helper= \
    -c 'credential.helper=!gh auth git-credential' \
    push "https://github.com/$repository.git" "HEAD:refs/heads/$branch"
}

PHASE="snapshot"
REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
REMOTE_URL="https://github.com/$REPOSITORY.git"
git -C "$ROOT" \
  -c credential.helper= \
  -c 'credential.helper=!gh auth git-credential' \
  fetch --quiet "$REMOTE_URL" "refs/heads/$BASE_BRANCH"
BASE_SHA="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
BRANCH="$(git -C "$ROOT" branch --show-current)"

if [ -z "$BRANCH" ]; then
  echo "A detached checkout cannot be released." >&2
  exit 1
fi
if [ "$BRANCH" = "$BASE_BRANCH" ]; then
  BRANCH="codex/release-$(date -u +%Y%m%d-%H%M%S)"
  git -C "$ROOT" switch -c "$BRANCH"
fi

if [ -z "$TITLE" ]; then
  TITLE="$(git -C "$ROOT" log -1 --pretty=%s)"
  if [ "$(git -C "$ROOT" rev-parse HEAD)" = "$BASE_SHA" ] || \
     [ -n "$(git -C "$ROOT" status --porcelain=v1)" ]; then
    TITLE="Release local changes"
  fi
fi

git -C "$ROOT" add -A
if ! git -C "$ROOT" diff --cached --quiet; then
  git -C "$ROOT" commit -m "$TITLE"
fi
if ! git -C "$ROOT" merge-base --is-ancestor "$BASE_SHA" HEAD; then
  echo "Integrating current $BASE_BRANCH into the release tree..."
  git -C "$ROOT" merge --no-edit "$BASE_SHA"
fi
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
TREE_SHA="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
if [ "$HEAD_SHA" = "$BASE_SHA" ]; then
  echo "There are no local changes or commits to release." >&2
  exit 1
fi
if [ -n "$(git -C "$ROOT" status --porcelain=v1)" ]; then
  echo "Failed to capture the complete working tree in the release commit." >&2
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

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/neoanki2-fast-release.XXXXXX")"
ARTIFACT_DIR="$WORK_DIR/artifacts"
BUILD_LOG="$WORK_DIR/build.log"
TEST_LOG="$WORK_DIR/test.log"
BODY_FILE="$WORK_DIR/pr-body.md"
CASK_FILE="$WORK_DIR/neoanki2.rb"
mkdir -p "$ARTIFACT_DIR"

cat > "$BODY_FILE" <<EOF
## Summary

$TITLE

## Release verification

- Exact local tree captured at \`$HEAD_SHA\`
- Fast headless suite and universal release build run locally before merge
- Exhaustive Test and Documentation workflows run automatically on the merged \`main\` revision
EOF

PHASE="parallel-local-validation"
echo "Building $TAG and running fast verification concurrently (300-second release SLO)..."
BUILD_STARTED_AT="$(date +%s)"
(
  NEOANKI_RELEASE_BUILD_NUMBER="$BUILD_NUMBER" \
  NEOANKI_RELEASE_VERSION="$VERSION" \
    "$ROOT/Scripts/build-release-artifact.sh" "$ARTIFACT_DIR"
) >"$BUILD_LOG" 2>&1 &
BUILD_PID="$!"
TEST_STARTED_AT="$(date +%s)"
(cd "$ROOT" && ./Scripts/test-fast.sh) >"$TEST_LOG" 2>&1 &
TEST_PID="$!"

PHASE="push-and-pr"
push_branch "$REPOSITORY" "$BRANCH"
PR_NUMBER="$(gh pr list --repo "$REPOSITORY" --head "$BRANCH" \
  --base "$BASE_BRANCH" --state open --limit 1 --json number --jq '.[0].number // empty')"
if [ -z "$PR_NUMBER" ]; then
  PR_URL="$(gh pr create --repo "$REPOSITORY" --base "$BASE_BRANCH" \
    --head "$BRANCH" --title "$TITLE" --body-file "$BODY_FILE")"
  PR_NUMBER="$(gh pr view "$PR_URL" --repo "$REPOSITORY" --json number --jq .number)"
else
  PR_URL="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" --json url --jq .url)"
fi
echo "PR #$PR_NUMBER records the exact release revision while local gates finish."

PHASE="parallel-local-validation"
LOCAL_FAILURE=0
if wait "$BUILD_PID"; then
  BUILD_SECONDS="$(($(date +%s) - BUILD_STARTED_AT))"
  BUILD_PID=""
  echo "Universal artifact built in ${BUILD_SECONDS}s."
else
  BUILD_SECONDS="$(($(date +%s) - BUILD_STARTED_AT))"
  BUILD_PID=""
  echo "Universal artifact build failed:" >&2
  tail -n 160 "$BUILD_LOG" >&2
  LOCAL_FAILURE=1
fi
if wait "$TEST_PID"; then
  TEST_SECONDS="$(($(date +%s) - TEST_STARTED_AT))"
  TEST_PID=""
  echo "Fast verification passed in ${TEST_SECONDS}s."
else
  TEST_SECONDS="$(($(date +%s) - TEST_STARTED_AT))"
  TEST_PID=""
  echo "Fast verification failed:" >&2
  tail -n 160 "$TEST_LOG" >&2
  LOCAL_FAILURE=1
fi
if [ "$LOCAL_FAILURE" -ne 0 ]; then
  exit 1
fi
require_budget 75 "merge, publication, and Homebrew installation"

CHECKSUM="$(shasum -a 256 "$ARTIFACT_DIR/$ARTIFACT" | awk '{print $1}')"
if [ "$(awk '{print $1}' "$ARTIFACT_DIR/$ARTIFACT.sha256")" != "$CHECKSUM" ]; then
  echo "Generated artifact and checksum file disagree." >&2
  exit 1
fi
PHASE="merge"
REMOTE_STARTED_AT="$(date +%s)"
CURRENT_LATEST_TAG="$(gh release view --repo "$REPOSITORY" --json tagName --jq .tagName)"
if [ "$CURRENT_LATEST_TAG" != "$LATEST_TAG" ]; then
  echo "Another release published $CURRENT_LATEST_TAG while $TAG was building." >&2
  exit 1
fi
REMOTE_PR_HEAD="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" --json headRefOid --jq .headRefOid)"
if [ "$REMOTE_PR_HEAD" != "$HEAD_SHA" ]; then
  echo "PR #$PR_NUMBER moved away from the locally verified revision." >&2
  exit 1
fi
CURRENT_BASE_SHA="$(gh api "repos/$REPOSITORY/git/ref/heads/$BASE_BRANCH" --jq .object.sha)"
PR_BASE_SHA="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" --json baseRefOid --jq .baseRefOid)"
if [ "$CURRENT_BASE_SHA" != "$BASE_SHA" ] || [ "$PR_BASE_SHA" != "$BASE_SHA" ]; then
  echo "$BASE_BRANCH advanced while $TAG was building; refusing to merge a different tree." >&2
  exit 1
fi
if gh pr merge "$PR_NUMBER" --repo "$REPOSITORY" --admin --merge --delete-branch; then
  VALIDATION_SHA="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" --json mergeCommit --jq .mergeCommit.oid)"
  if [ -z "$VALIDATION_SHA" ] || [ "$VALIDATION_SHA" = "null" ]; then
    echo "PR #$PR_NUMBER merged without exposing its validation revision." >&2
    exit 1
  fi
  MERGE_TREE_SHA="$(gh api "repos/$REPOSITORY/git/commits/$VALIDATION_SHA" --jq .tree.sha)"
  if [ "$MERGE_TREE_SHA" != "$TREE_SHA" ]; then
    echo "Merged revision tree $MERGE_TREE_SHA does not match released tree $TREE_SHA." >&2
    exit 1
  fi
  VALIDATION_KIND="merged-main"
else
  echo "Branch protection forbids immediate merge; publishing the exact verified PR head."
  gh pr merge "$PR_NUMBER" --repo "$REPOSITORY" --auto --merge --delete-branch >/dev/null 2>&1 || true
  VALIDATION_SHA="$HEAD_SHA"
  VALIDATION_KIND="protected-pr-pending"
fi

PHASE="manifest"
jq -n \
  --arg repository "$REPOSITORY" \
  --argjson pullRequest "$PR_NUMBER" \
  --arg headSha "$HEAD_SHA" \
  --arg validationSha "$VALIDATION_SHA" \
  --arg validationKind "$VALIDATION_KIND" \
  --arg baseSha "$BASE_SHA" \
  --arg baseBranch "$BASE_BRANCH" \
  --arg treeSha "$TREE_SHA" \
  --arg version "$VERSION" \
  --arg tag "$TAG" \
  --argjson buildNumber "$BUILD_NUMBER" \
  --arg artifact "$ARTIFACT" \
  --arg checksum "$CHECKSUM" \
  --arg previousTag "$LATEST_TAG" \
  --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    schemaVersion: 2,
    releaseMode: "local-fast",
    verification: "local-fast-passed; post-release-ci-automatic",
    repository: $repository,
    pullRequest: $pullRequest,
    headSha: $headSha,
    validationSha: $validationSha,
    validationKind: $validationKind,
    baseSha: $baseSha,
    baseBranch: $baseBranch,
    treeSha: $treeSha,
    version: $version,
    tag: $tag,
    buildNumber: $buildNumber,
    artifact: $artifact,
    checksum: $checksum,
    previousTag: $previousTag,
    createdAt: $createdAt
  }' > "$ARTIFACT_DIR/release-candidate.json"

cat > "$WORK_DIR/release-notes.md" <<EOF
$TITLE

- Source revision: \`$HEAD_SHA\`
- Validation revision: \`$VALIDATION_SHA\` (\`$VALIDATION_KIND\`)
- Local fast suite: passed
- Full Test and Documentation workflows: running automatically for PR #$PR_NUMBER
EOF

PHASE="publish"
gh release create "$TAG" \
  "$ARTIFACT_DIR/$ARTIFACT" \
  "$ARTIFACT_DIR/$ARTIFACT.sha256" \
  "$ARTIFACT_DIR/release-candidate.json" \
  --repo "$REPOSITORY" \
  --target "$HEAD_SHA" \
  --title "NeoAnki2 $VERSION" \
  --notes-file "$WORK_DIR/release-notes.md"

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

PHASE="tap"
TAP_REPOSITORY="neoanki2/homebrew-tap"
ENCODED_CASK="$(base64 < "$CASK_FILE" | tr -d '\n')"
UPDATED_TAP=0
for attempt in 1 2 3; do
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
  echo "Tap changed concurrently; retrying ($attempt/3)." >&2
done
if [ "$UPDATED_TAP" -ne 1 ]; then
  echo "Unable to update the official Homebrew tap." >&2
  exit 1
fi
REMOTE_SECONDS="$(($(date +%s) - REMOTE_STARTED_AT))"
echo "Published $TAG and updated the official tap in ${REMOTE_SECONDS}s."

if [ "$INSTALL" -eq 1 ]; then
  require_budget 35 "Homebrew replacement and launch verification"
  PHASE="homebrew-install"
  INSTALL_STARTED_AT="$(date +%s)"
  TAP_DIRECTORY="$(brew --repository neoanki2/tap)"
  (cd "$TAP_DIRECTORY" && gh repo sync --branch main)
  TAP_VERSION="$(brew info --cask neoanki2/tap/neoanki2 --json=v2 | jq -r '.casks[0].version')"
  if [ "$TAP_VERSION" != "$VERSION" ]; then
    echo "Homebrew resolved $TAP_VERSION; expected $VERSION." >&2
    exit 1
  fi

  APP_PATH="/Applications/NeoAnki2.app"
  APP_EXECUTABLE="$APP_PATH/Contents/MacOS/NeoAnki2"
  APP_WAS_RUNNING=0
  pgrep -x NeoAnki2 >/dev/null 2>&1 && APP_WAS_RUNNING=1
  SHOULD_LAUNCH="$LAUNCH"
  [ "$APP_WAS_RUNNING" -eq 1 ] && SHOULD_LAUNCH=1

  if [ "$APP_WAS_RUNNING" -eq 1 ]; then
    /usr/bin/osascript -e 'tell application id "com.neoanki2.app" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      pgrep -x NeoAnki2 >/dev/null 2>&1 || break
      sleep 0.25
    done
    if pgrep -x NeoAnki2 >/dev/null 2>&1; then
      while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        process_command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$process_command" != */NeoAnki2.app/Contents/MacOS/NeoAnki2* ]]; then
          echo "Refusing to signal unexpected NeoAnki2 process $pid: $process_command" >&2
          exit 1
        fi
        kill -TERM "$pid" 2>/dev/null || true
      done < <(pgrep -x NeoAnki2 2>/dev/null || true)
      for _ in $(seq 1 40); do
        pgrep -x NeoAnki2 >/dev/null 2>&1 || break
        sleep 0.25
      done
    fi
    if pgrep -x NeoAnki2 >/dev/null 2>&1; then
      echo "NeoAnki2 did not stop safely; refusing to replace it." >&2
      exit 1
    fi
  fi

  if brew list --cask neoanki2/tap/neoanki2 >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
      brew upgrade --cask neoanki2/tap/neoanki2 --no-quit --require-sha -y
  else
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
      brew install --cask neoanki2/tap/neoanki2 --require-sha
  fi

  INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
  INSTALLED_REVISION="$(/usr/libexec/PlistBuddy -c 'Print :NeoAnkiGitRevision' "$APP_PATH/Contents/Info.plist")"
  if [ "$INSTALLED_VERSION" != "$VERSION" ] || [[ "$HEAD_SHA" != "$INSTALLED_REVISION"* ]]; then
    echo "Installed app metadata does not match $VERSION at $HEAD_SHA." >&2
    exit 1
  fi
  codesign --verify --deep --strict "$APP_PATH"

  if [ "$SHOULD_LAUNCH" -eq 1 ]; then
    /usr/bin/open "$APP_PATH"
    for _ in $(seq 1 40); do
      pgrep -x NeoAnki2 >/dev/null 2>&1 && break
      sleep 0.25
    done
    RUNNING_EXACT_APP=0
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      process_command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      if [[ "$process_command" == "$APP_EXECUTABLE"* ]]; then
        RUNNING_EXACT_APP=1
      else
        echo "A NeoAnki2 process is running from an unexpected path: $process_command" >&2
        exit 1
      fi
    done < <(pgrep -x NeoAnki2 2>/dev/null || true)
    if [ "$RUNNING_EXACT_APP" -ne 1 ]; then
      echo "The single launch attempt did not start $APP_EXECUTABLE." >&2
      exit 1
    fi
  fi
  INSTALL_SECONDS="$(($(date +%s) - INSTALL_STARTED_AT))"
fi

PHASE="complete"
ELAPSED="$(($(date +%s) - STARTED_AT))"
if [ "$ELAPSED" -gt "$SLO_SECONDS" ]; then
  echo "Release completed in ${ELAPSED}s, exceeding the ${SLO_SECONDS}s SLO." >&2
  exit 1
fi
echo "Released and installed $TAG from local revision $HEAD_SHA in ${ELAPSED}s."
echo "FAST_RELEASE_PR=$PR_URL"
echo "FAST_RELEASE_TAG=$TAG"
echo "FAST_RELEASE_REVISION=$HEAD_SHA"
