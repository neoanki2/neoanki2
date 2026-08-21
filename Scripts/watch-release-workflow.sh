#!/usr/bin/env bash
set -euo pipefail

REPOSITORY=""
RUN_ID=""
LABEL="workflow"
MAX_ATTEMPTS="${RELEASE_WORKFLOW_RERUN_MAX_ATTEMPTS:-30}"
SLEEP_SECONDS="${RELEASE_WORKFLOW_RERUN_SLEEP_SECONDS:-2}"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/watch-release-workflow.sh \
  --repo OWNER/REPO --run RUN_ID [--label DESCRIPTION]

Watches an exact GitHub Actions run. If the selected run already completed
with a retryable failure, starts one new attempt and waits until GitHub exposes
that attempt before watching it. Approval-required runs are never retried.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPOSITORY="${2:?--repo needs OWNER/REPO}"; shift 2 ;;
    --run) RUN_ID="${2:?--run needs an ID}"; shift 2 ;;
    --label) LABEL="${2:?--label needs text}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$REPOSITORY" ] || [[ ! "$RUN_ID" =~ ^[0-9]+$ ]]; then
  usage
  exit 2
fi
if [[ ! "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || \
   [[ ! "$SLEEP_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Release workflow retry timing is invalid." >&2
  exit 2
fi

read_run_state() {
  gh run view "$RUN_ID" --repo "$REPOSITORY" \
    --json attempt,status,conclusion \
    --jq '[.attempt, .status, (.conclusion // "")] | @tsv'
}

IFS=$'\t' read -r INITIAL_ATTEMPT STATUS CONCLUSION <<<"$(read_run_state)"
if [ "$STATUS" = "completed" ] && [ "$CONCLUSION" != "success" ]; then
  case "$CONCLUSION" in
    failure|timed_out|cancelled|startup_failure|stale)
      echo "Retrying $LABEL run $RUN_ID after $CONCLUSION (attempt $INITIAL_ATTEMPT)."
      if [ "$CONCLUSION" = "failure" ] || [ "$CONCLUSION" = "timed_out" ]; then
        gh run rerun "$RUN_ID" --repo "$REPOSITORY" --failed
      else
        gh run rerun "$RUN_ID" --repo "$REPOSITORY"
      fi
      ;;
    action_required)
      echo "$LABEL run $RUN_ID requires approval; refusing an automatic retry." >&2
      exit 1
      ;;
    *)
      echo "$LABEL run $RUN_ID completed with non-retryable conclusion '$CONCLUSION'." >&2
      exit 1
      ;;
  esac

  RERUN_VISIBLE=0
  for _ in $(seq 1 "$MAX_ATTEMPTS"); do
    IFS=$'\t' read -r CURRENT_ATTEMPT STATUS CONCLUSION <<<"$(read_run_state)"
    if [ "$CURRENT_ATTEMPT" -gt "$INITIAL_ATTEMPT" ]; then
      RERUN_VISIBLE=1
      break
    fi
    sleep "$SLEEP_SECONDS"
  done
  if [ "$RERUN_VISIBLE" -ne 1 ]; then
    echo "GitHub did not expose the new attempt for $LABEL run $RUN_ID." >&2
    exit 1
  fi
fi

gh run watch "$RUN_ID" --repo "$REPOSITORY" --exit-status
