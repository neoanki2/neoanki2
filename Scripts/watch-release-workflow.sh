#!/usr/bin/env bash
set -euo pipefail

REPOSITORY=""
RUN_ID=""
LABEL="workflow"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/watch-release-workflow.sh \
  --repo OWNER/REPO --run RUN_ID [--label DESCRIPTION]

Watches an exact GitHub Actions run and reports its result.
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
echo "Watching $LABEL run $RUN_ID."
exec gh run watch "$RUN_ID" --repo "$REPOSITORY" --exit-status
