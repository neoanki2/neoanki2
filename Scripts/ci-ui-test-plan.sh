#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/Config/ci-ui-shards.json"
PLATFORM="${1:-}"

if [[ "$PLATFORM" != "macos" && "$PLATFORM" != "ios" ]]; then
  echo "Usage: $0 macos|ios" >&2
  exit 64
fi

jq -e '
  .schema_version == 1
  and (.macos | type == "array" and length > 0)
  and (.ios | type == "array" and length > 0)
  and ([.macos[].id, .ios[].id] | length == (unique | length))
  and all(.macos[]; (.tests | type == "array" and length > 0))
  and all(.ios[];
    (.device | type == "string" and length > 0)
    and (.workers | type == "number" and . >= 1 and . <= 4)
    and (.tests | type == "array" and length > 0))
' "$MANIFEST" >/dev/null

jq -c --arg platform "$PLATFORM" '
  {
    include: .[$platform] | map(
      . + {tests: (.tests | join(","))}
    )
  }
' "$MANIFEST"
