#!/usr/bin/env bash
set -euo pipefail

REPOSITORY=""
PR_NUMBER=""
HEAD_SHA=""
PR_BRANCH=""
BASE_SHA=""
MAX_ATTEMPTS="${RELEASE_RECONCILE_MAX_ATTEMPTS:-15}"
SLEEP_SECONDS="${RELEASE_RECONCILE_SLEEP_SECONDS:-2}"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/reconcile-release-workflows.sh \
  --repo OWNER/REPO --pr NUMBER --head SHA --branch BRANCH --base SHA

Reconciles checks after the documentation screenshot bot promotes a new pull-
request revision. Known GitHub Actions bot runs that require approval are
approved for the exact PR head. If automatic Documentation or Test runs do not
exist, exact-head workflow_dispatch fallbacks are started instead.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPOSITORY="${2:?--repo needs OWNER/REPO}"; shift 2 ;;
    --pr) PR_NUMBER="${2:?--pr needs a number}"; shift 2 ;;
    --head) HEAD_SHA="${2:?--head needs a revision}"; shift 2 ;;
    --branch) PR_BRANCH="${2:?--branch needs a branch}"; shift 2 ;;
    --base) BASE_SHA="${2:?--base needs a revision}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$REPOSITORY" ] || [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]] || \
   [ -z "$HEAD_SHA" ] || [ -z "$PR_BRANCH" ] || [ -z "$BASE_SHA" ]; then
  usage
  exit 2
fi
if [[ ! "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || \
   [[ ! "$SLEEP_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Release workflow reconciliation timing is invalid." >&2
  exit 2
fi

for command in gh jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

KNOWN_PATHS_JQ='[
  ".github/workflows/docs-screenshots.yml",
  ".github/workflows/docs-pages.yml",
  ".github/workflows/test.yml"
]'

get_exact_head_runs() {
  gh api --paginate \
    "repos/$REPOSITORY/actions/runs?head_sha=$HEAD_SHA&per_page=100" \
    | jq -s '[.[].workflow_runs[]]'
}

get_unrecognized_action_required() {
  jq -r \
    --argjson pr "$PR_NUMBER" \
    --argjson paths "$KNOWN_PATHS_JQ" '
      .[]
      | select(.event == "pull_request")
      | select(.conclusion == "action_required")
      | select(any(.pull_requests[]?; .number == $pr))
      | select(.actor.login != "github-actions[bot]" or
               (.path as $path | all($paths[]; . != $path)))
      | "\(.id) \(.path) actor=\(.actor.login)"
    '
}

RUNS_JSON='[]'
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  CURRENT_HEAD="$(gh pr view "$PR_NUMBER" --repo "$REPOSITORY" \
    --json headRefOid --jq .headRefOid)"
  if [ "$CURRENT_HEAD" != "$HEAD_SHA" ]; then
    echo "PR #$PR_NUMBER moved from $HEAD_SHA to $CURRENT_HEAD during workflow reconciliation." >&2
    exit 1
  fi

  RUNS_JSON="$(get_exact_head_runs)"
  APPROVAL_IDS="$(jq -r \
    --argjson pr "$PR_NUMBER" \
    --argjson paths "$KNOWN_PATHS_JQ" '
      .[]
      | select(.event == "pull_request")
      | select(.conclusion == "action_required")
      | select(.actor.login == "github-actions[bot]")
      | select(.path as $path | any($paths[]; . == $path))
      | select(any(.pull_requests[]?; .number == $pr))
      | .id
    ' <<<"$RUNS_JSON")"
  while IFS= read -r approval_id; do
    [ -n "$approval_id" ] || continue
    echo "Approving known bot workflow $approval_id for exact PR head $HEAD_SHA."
    gh api --method POST \
      "repos/$REPOSITORY/actions/runs/$approval_id/approve" >/dev/null
  done <<<"$APPROVAL_IDS"

  if [ -n "$APPROVAL_IDS" ]; then
    sleep "$SLEEP_SECONDS"
    continue
  fi

  UNRECOGNIZED_ACTION_REQUIRED="$(get_unrecognized_action_required \
    <<<"$RUNS_JSON")"
  if [ -n "$UNRECOGNIZED_ACTION_REQUIRED" ]; then
    echo "Unrecognized action-required workflows need manual review:" >&2
    echo "$UNRECOGNIZED_ACTION_REQUIRED" >&2
    exit 1
  fi

  TEST_PRESENT="$(jq -r '
    any(.[]; .path == ".github/workflows/test.yml")
  ' <<<"$RUNS_JSON")"
  DOCS_PRESENT="$(jq -r '
    any(.[]; .path == ".github/workflows/docs-pages.yml")
  ' <<<"$RUNS_JSON")"
  if [ "$TEST_PRESENT" = "true" ] && [ "$DOCS_PRESENT" = "true" ]; then
    echo "Exact-head Documentation and Test workflows are present."
    exit 0
  fi

  [ "$attempt" -lt "$MAX_ATTEMPTS" ] && sleep "$SLEEP_SECONDS"
done

UNRECOGNIZED_ACTION_REQUIRED="$(get_unrecognized_action_required \
  <<<"$RUNS_JSON")"
if [ -n "$UNRECOGNIZED_ACTION_REQUIRED" ]; then
  echo "Unrecognized action-required workflows need manual review:" >&2
  echo "$UNRECOGNIZED_ACTION_REQUIRED" >&2
  exit 1
fi

TEST_PRESENT="$(jq -r '
  any(.[]; .path == ".github/workflows/test.yml")
' <<<"$RUNS_JSON")"
DOCS_PRESENT="$(jq -r '
  any(.[]; .path == ".github/workflows/docs-pages.yml")
' <<<"$RUNS_JSON")"

if [ "$DOCS_PRESENT" != "true" ]; then
  echo "Dispatching missing exact-head Documentation workflow for $HEAD_SHA."
  gh workflow run docs-pages.yml --repo "$REPOSITORY" --ref "$PR_BRANCH" \
    -f "base_ref=$BASE_SHA"
fi
if [ "$TEST_PRESENT" != "true" ]; then
  echo "Dispatching missing exact-head Test workflow for $HEAD_SHA."
  gh workflow run test.yml --repo "$REPOSITORY" --ref "$PR_BRANCH"
fi
