#!/usr/bin/env bash
set -euo pipefail

# Keep failed response bodies out of the successful JSON consumed by callers.
for attempt in 1 2 3 4 5; do
  if response="$(gh "$@")"; then
    printf '%s\n' "$response"
    exit 0
  fi
  if [ "$attempt" -eq 5 ]; then
    exit 1
  fi
  echo "GitHub CLI read failed; retrying in $((attempt * 2)) seconds..." >&2
  sleep "$((attempt * 2))"
done
