#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--stress" ]]; then
  export NEOANKI_SYNC_FUZZ_SEEDS="${NEOANKI_SYNC_FUZZ_SEEDS:-32}"
  export NEOANKI_SYNC_FUZZ_STEPS="${NEOANKI_SYNC_FUZZ_STEPS:-200}"
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--stress]" >&2
  exit 2
fi

for setting in NEOANKI_SYNC_FUZZ_SEEDS NEOANKI_SYNC_FUZZ_STEPS NEOANKI_SYNC_FUZZ_SEED; do
  value="${!setting:-}"
  if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$setting must be a nonnegative decimal integer." >&2
    exit 2
  fi
done

# Includes named regression tests as well as state-machine/fault/property tests.
# Everything uses temporary databases and in-process CloudKit record objects.
swift test --filter 'SyncStateMachineTests|SyncMetadataStoreTests|SyncMergePolicyTests|OfflineFirstSyncServiceTests|CKSyncEngineTransportTests|sqliteSyncAdapter|syncAdapter|initialMerge|linkedLibraries|itemTypeSyncEnvelope|syncMetadataStages|synchronized'
