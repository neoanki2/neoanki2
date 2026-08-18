#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_BRANCH="main"
PR_NUMBER=""
TITLE=""
BODY_FILE=""
INSTALL=1
LAUNCH=1

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/release.sh [--pr NUMBER | --title TITLE --body-file FILE] [options]

Options:
  --base BRANCH     Pull-request base branch (default: main)
  --no-install      Publish and update the tap without upgrading this Mac
  --no-launch       Install but leave NeoAnki2 closed when it began closed

Without --pr, run this command from a clean feature branch. It validates the
branch, pushes through gh authentication, creates or reuses a pull request,
waits for any required CI screenshot promotion, builds an attested candidate
in parallel with required checks, waits, and then promotes it with safe resume
support, upgrades Homebrew, and launches the exact installed app. NeoAnki2
stays open until the replacement is ready.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_BRANCH="${2:?--base needs a branch}"; shift 2 ;;
    --pr) PR_NUMBER="${2:?--pr needs a number}"; shift 2 ;;
    --title) TITLE="${2:?--title needs text}"; shift 2 ;;
    --body-file) BODY_FILE="${2:?--body-file needs a file}"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --launch) LAUNCH=1; shift ;;
    --no-install) INSTALL=0; LAUNCH=0; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -n "$PR_NUMBER" ] && [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "--pr must be a numeric pull-request number." >&2
  exit 2
fi
if [ -z "$PR_NUMBER" ] && { [ -z "$TITLE" ] || [ ! -f "$BODY_FILE" ]; }; then
  echo "Use --pr NUMBER to resume, or provide --title and an existing --body-file." >&2
  exit 2
fi
if [ "$LAUNCH" -eq 1 ] && [ "$INSTALL" -ne 1 ]; then
  echo "--launch requires --install." >&2
  exit 2
fi

for command in gh git jq python3 swift; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done
gh auth status >/dev/null

REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

if [ -z "$PR_NUMBER" ]; then
  BRANCH="$(git -C "$ROOT" branch --show-current)"
  HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  REMOTE_BASE_SHA="$(gh api "repos/$REPOSITORY/git/ref/heads/$BASE_BRANCH" --jq .object.sha)"
  git -C "$ROOT" \
    -c credential.helper= \
    -c 'credential.helper=!gh auth git-credential' \
    fetch --quiet "https://github.com/$REPOSITORY.git" \
    "refs/heads/$BASE_BRANCH"
  BASE_SHA="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
  if [ "$BASE_SHA" != "$REMOTE_BASE_SHA" ]; then
    echo "Fetched $BASE_BRANCH does not match GitHub's current revision." >&2
    exit 1
  fi

  if [ -z "$BRANCH" ] || [ "$BRANCH" = "$BASE_BRANCH" ]; then
    echo "Start a release from a feature branch, not $BASE_BRANCH." >&2
    exit 1
  fi
  if [ -n "$(git -C "$ROOT" status --porcelain=v1)" ]; then
    echo "The worktree must be clean before release." >&2
    exit 1
  fi
  if ! git -C "$ROOT" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA"; then
    echo "$BRANCH is not based on the current $BASE_BRANCH revision." >&2
    exit 1
  fi

  REMOTE_BRANCH_EXISTS=0
  REMOTE_SHA=""
  if gh api "repos/$REPOSITORY/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
    REMOTE_BRANCH_EXISTS=1
    REMOTE_SHA="$(gh api "repos/$REPOSITORY/git/ref/heads/$BRANCH" --jq .object.sha)"
  fi
  EXISTING_PR_NUMBER="$(gh pr list --repo "$REPOSITORY" --head "$BRANCH" \
    --base "$BASE_BRANCH" --state all --limit 1 --json number --jq '.[0].number // empty')"

  NEEDS_PUSH=0
  if [ "$REMOTE_BRANCH_EXISTS" -ne 1 ]; then
    NEEDS_PUSH=1
  elif [ "$REMOTE_SHA" != "$HEAD_SHA" ]; then
    if ! git -C "$ROOT" merge-base --is-ancestor "$REMOTE_SHA" "$HEAD_SHA"; then
      echo "Remote branch $BRANCH diverged from local HEAD; refusing to overwrite it." >&2
      exit 1
    fi
    NEEDS_PUSH=1
  fi

  if [ "$NEEDS_PUSH" -eq 1 ] || [ -z "$EXISTING_PR_NUMBER" ]; then
    echo "Running local release preflight..."
    (cd "$ROOT" && swift build)
    (cd "$ROOT" && ./Scripts/test-fast.sh)
    bash -n "$ROOT/Scripts/release.sh" \
      "$ROOT/Scripts/build-release-candidate.sh" \
      "$ROOT/Scripts/publish-release-candidate.sh" \
      "$ROOT/Scripts/ship-release.sh"

  fi

  if [ "$NEEDS_PUSH" -eq 1 ]; then
    echo "Pushing $BRANCH with GitHub CLI credentials..."
    git -C "$ROOT" \
      -c credential.helper= \
      -c 'credential.helper=!gh auth git-credential' \
      push "https://github.com/$REPOSITORY.git" \
      "HEAD:refs/heads/$BRANCH"
  else
    echo "Remote branch already matches HEAD; skipping push."
  fi

  PR_NUMBER="$EXISTING_PR_NUMBER"
  if [ -z "$PR_NUMBER" ]; then
    PR_URL="$(gh pr create --repo "$REPOSITORY" --base "$BASE_BRANCH" \
      --head "$BRANCH" --title "$TITLE" --body-file "$BODY_FILE")"
    PR_NUMBER="$(gh pr view "$PR_URL" --repo "$REPOSITORY" --json number --jq .number)"
  fi

  PR_HEAD_MATCHES=0
  for _ in $(seq 1 30); do
    REMOTE_PR_HEAD="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" \
      --json headRefOid --jq .headRefOid)"
    if [ "$REMOTE_PR_HEAD" = "$HEAD_SHA" ]; then
      PR_HEAD_MATCHES=1
      break
    fi
    echo "Waiting for PR #$PR_NUMBER to expose pushed head $HEAD_SHA..."
    sleep 1
  done
  if [ "$PR_HEAD_MATCHES" -ne 1 ]; then
    echo "PR #$PR_NUMBER did not converge to pushed head $HEAD_SHA." >&2
    exit 1
  fi
fi

PR_JSON="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" \
  --json state,isDraft,headRefOid,headRefName)"
PR_STATE="$(jq -r .state <<<"$PR_JSON")"
HEAD_SHA="$(jq -r .headRefOid <<<"$PR_JSON")"
PR_BRANCH="$(jq -r .headRefName <<<"$PR_JSON")"

if [ "$PR_STATE" = "OPEN" ]; then
  for capture_attempt in $(seq 1 4); do
    git -C "$ROOT" \
      -c credential.helper= \
      -c 'credential.helper=!gh auth git-credential' \
      fetch --quiet "https://github.com/$REPOSITORY.git" "$HEAD_SHA"
    SCREENSHOTS_NEEDED="$(python3 "$ROOT/Scripts/documentation-screenshots-needed.py" \
      --revision "$HEAD_SHA")"
    if [ "$SCREENSHOTS_NEEDED" = "false" ]; then
      break
    fi

    echo "Waiting for CI to capture and promote documentation screenshots for $HEAD_SHA..."
    SCREENSHOT_RUN_ID=""
    for run_attempt in $(seq 1 30); do
      SCREENSHOT_RUN_ID="$(gh run list --repo "$REPOSITORY" \
        --workflow docs-screenshots.yml --branch "$PR_BRANCH" \
        --event pull_request --limit 20 \
        --json databaseId,headSha \
        --jq ".[] | select(.headSha == \"$HEAD_SHA\") | .databaseId" \
        | head -n 1)"
      [ -n "$SCREENSHOT_RUN_ID" ] && break
      sleep 2
    done
    if [ -z "$SCREENSHOT_RUN_ID" ]; then
      echo "Documentation screenshot capture did not start for $HEAD_SHA." >&2
      exit 1
    fi
    gh run watch "$SCREENSHOT_RUN_ID" --repo "$REPOSITORY" --exit-status

    CAPTURED_HEAD="$HEAD_SHA"
    for promotion_attempt in $(seq 1 30); do
      HEAD_SHA="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" \
        --json headRefOid --jq .headRefOid)"
      [ "$HEAD_SHA" != "$CAPTURED_HEAD" ] && break
      sleep 1
    done
    if [ "$HEAD_SHA" = "$CAPTURED_HEAD" ]; then
      echo "Screenshot capture completed without promoting a new PR revision." >&2
      exit 1
    fi
    echo "CI promoted documentation screenshots in $HEAD_SHA."
  done

  git -C "$ROOT" \
    -c credential.helper= \
    -c 'credential.helper=!gh auth git-credential' \
    fetch --quiet "https://github.com/$REPOSITORY.git" "$HEAD_SHA"
  if [ "$(python3 "$ROOT/Scripts/documentation-screenshots-needed.py" \
    --revision "$HEAD_SHA")" != "false" ]; then
    echo "Documentation screenshots are still stale after CI promotion." >&2
    exit 1
  fi

  if [ "$(jq -r .isDraft <<<"$PR_JSON")" = "true" ]; then
    gh pr ready "$PR_NUMBER" --repo "$REPOSITORY"
  fi

  LATEST_TAG="$(gh release view --repo "$REPOSITORY" --json tagName --jq .tagName)"
  if [[ ! "$LATEST_TAG" =~ ^v1[.]0[.]([0-9]+)$ ]]; then
    echo "Latest release tag has an unsupported format: $LATEST_TAG" >&2
    exit 1
  fi
  CANDIDATE_TAG="v1.0.$((BASH_REMATCH[1] + 1))"

  CANDIDATE_READY=0
  if CANDIDATE_JSON="$(gh release view "$CANDIDATE_TAG" --repo "$REPOSITORY" \
    --json isDraft,targetCommitish,assets 2>/dev/null)"; then
    if [ "$(jq -r .isDraft <<<"$CANDIDATE_JSON")" = "true" ] && \
       [ "$(jq -r .targetCommitish <<<"$CANDIDATE_JSON")" = "$HEAD_SHA" ] && \
       jq -e '.assets[] | select(.name == "release-candidate.json")' \
         <<<"$CANDIDATE_JSON" >/dev/null; then
      CANDIDATE_READY=1
      echo "Reusing tested draft candidate $CANDIDATE_TAG."
    else
      STALE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/neoanki2-stale-candidate.XXXXXX")"
      if [ "$(jq -r .isDraft <<<"$CANDIDATE_JSON")" = "true" ] && \
         jq -e '.assets[] | select(.name == "release-candidate.json")' \
           <<<"$CANDIDATE_JSON" >/dev/null && \
         gh release download "$CANDIDATE_TAG" --repo "$REPOSITORY" \
           --pattern release-candidate.json --dir "$STALE_DIR" >/dev/null && \
         [ "$(jq -r .pullRequest "$STALE_DIR/release-candidate.json")" = "$PR_NUMBER" ]; then
        echo "Removing stale draft $CANDIDATE_TAG for the previous PR head."
        gh release delete "$CANDIDATE_TAG" --repo "$REPOSITORY" --yes
        rm -rf "$STALE_DIR"
      else
        rm -rf "$STALE_DIR"
        echo "$CANDIDATE_TAG already belongs to another release transaction." >&2
        exit 1
      fi
    fi
  fi

  if [ "$CANDIDATE_READY" -ne 1 ]; then
    STALE_RUN_IDS="$(gh run list --repo "$REPOSITORY" \
      --workflow release-candidate.yml --limit 50 \
      --json databaseId,headBranch,headSha,status \
      --jq ".[] | select(.headBranch == \"$PR_BRANCH\" and .headSha != \"$HEAD_SHA\" and .status != \"completed\") | .databaseId")"
    while IFS= read -r stale_run_id; do
      [ -n "$stale_run_id" ] || continue
      echo "Cancelling stale candidate workflow $stale_run_id for the previous PR head."
      gh run cancel "$stale_run_id" --repo "$REPOSITORY"
    done <<<"$STALE_RUN_IDS"

    RUN_ID="$(gh run list --repo "$REPOSITORY" \
      --workflow release-candidate.yml --limit 50 \
      --json databaseId,headBranch,headSha,status \
      --jq ".[] | select(.headBranch == \"$PR_BRANCH\" and .headSha == \"$HEAD_SHA\" and .status != \"completed\") | .databaseId" \
      | head -n 1)"
    if [ -z "$RUN_ID" ]; then
      gh workflow run release-candidate.yml --repo "$REPOSITORY" \
        --ref "$PR_BRANCH" -f "pr=$PR_NUMBER" -f "head=$HEAD_SHA"
      for _ in $(seq 1 20); do
        RUN_ID="$(gh run list --repo "$REPOSITORY" \
          --workflow release-candidate.yml --limit 20 \
          --json databaseId,headBranch,headSha \
          --jq ".[] | select(.headBranch == \"$PR_BRANCH\" and .headSha == \"$HEAD_SHA\") | .databaseId" \
          | head -n 1)"
        [ -n "$RUN_ID" ] && break
        sleep 1
      done
    fi
    if [ -z "$RUN_ID" ]; then
      echo "Could not identify the dispatched release-candidate workflow run." >&2
      exit 1
    fi
    echo "Waiting for attested candidate workflow $RUN_ID..."
    gh run watch "$RUN_ID" --repo "$REPOSITORY" --exit-status
  fi

  echo "Candidate is ready; required checks are verified during promotion."
elif [ "$PR_STATE" != "MERGED" ]; then
  echo "Pull request #$PR_NUMBER is $PR_STATE; it cannot be released." >&2
  exit 1
fi

SHIP_ARGUMENTS=(--pr "$PR_NUMBER")
[ "$INSTALL" -eq 1 ] && SHIP_ARGUMENTS+=(--install)
[ "$LAUNCH" -eq 1 ] && SHIP_ARGUMENTS+=(--launch)
"$ROOT/Scripts/ship-release.sh" "${SHIP_ARGUMENTS[@]}"
