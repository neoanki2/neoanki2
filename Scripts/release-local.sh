#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE_DIR="$ROOT/.build/local-release-candidate"
BASE_BRANCH="main"
TITLE=""
BODY_FILE=""
INSTALL=0
MAX_PUSH_SECONDS=60

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/release-local.sh --title TITLE --body-file FILE [options]

Options:
  --candidate DIR       Candidate output directory
  --base BRANCH         Pull request base branch (default: main)
  --install             Upgrade the installed Homebrew cask without launching it
  --max-push-seconds N  Strict push-to-installed ceiling (default: 60)

Measures the complete local release path: validation, universal packaging,
draft upload, first push, PR merge, publication, tap update, and installation.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) CANDIDATE_DIR="${2:?--candidate needs a directory}"; shift 2 ;;
    --base) BASE_BRANCH="${2:?--base needs a branch}"; shift 2 ;;
    --title) TITLE="${2:?--title needs text}"; shift 2 ;;
    --body-file) BODY_FILE="${2:?--body-file needs a file}"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --max-push-seconds) MAX_PUSH_SECONDS="${2:?--max-push-seconds needs a number}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$TITLE" ] || [ ! -f "$BODY_FILE" ]; then
  echo "--title and an existing --body-file are required." >&2
  exit 2
fi

STARTED_AT="$(date +%s)"

"$ROOT/Scripts/prepare-local-release.sh" \
  --base "$BASE_BRANCH" \
  --output "$CANDIDATE_DIR"

PREPARED_AT="$(date +%s)"

SHIP_ARGUMENTS=(
  --candidate "$CANDIDATE_DIR"
  --title "$TITLE"
  --body-file "$BODY_FILE"
  --max-seconds "$MAX_PUSH_SECONDS"
)
if [ "$INSTALL" -eq 1 ]; then
  SHIP_ARGUMENTS+=(--install)
fi

"$ROOT/Scripts/push-ship-release.sh" "${SHIP_ARGUMENTS[@]}"

FINISHED_AT="$(date +%s)"
echo "FULL_PREPARE_SECONDS=$((PREPARED_AT - STARTED_AT))"
echo "FULL_PROMOTE_SECONDS=$((FINISHED_AT - PREPARED_AT))"
echo "FULL_RELEASE_SECONDS=$((FINISHED_AT - STARTED_AT))"
