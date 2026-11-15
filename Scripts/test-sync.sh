#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CALLER_DIR="$PWD"
CONTRACTS_ONLY=0
STRESS=0

usage() {
  cat <<'USAGE'
Usage: Scripts/test-sync.sh [--contracts] [--stress] [--replay SCENARIO.json]

  --contracts       Run autonomous visible-convergence contracts only.
  --stress          Expand the seeded scenarios for a longer headless run.
  --replay FILE     Replay a saved contract scenario (implies --contracts).

All runs use synthetic temporary libraries; no Apple account or device is used.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contracts) CONTRACTS_ONLY=1; shift ;;
    --stress) STRESS=1; shift ;;
    --replay)
      if [[ $# -lt 2 || -z "$2" ]]; then usage >&2; exit 2; fi
      case "$2" in
        /*) export NEOANKI_SYNC_CONTRACT_REPLAY="$2" ;;
        *) export NEOANKI_SYNC_CONTRACT_REPLAY="$CALLER_DIR/$2" ;;
      esac
      if [[ ! -r "$NEOANKI_SYNC_CONTRACT_REPLAY" ]]; then
        echo "Cannot read scenario: $NEOANKI_SYNC_CONTRACT_REPLAY" >&2
        exit 2
      fi
      CONTRACTS_ONLY=1
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ "$STRESS" == 1 ]]; then
  export NEOANKI_SYNC_FUZZ_SEEDS="${NEOANKI_SYNC_FUZZ_SEEDS:-32}"
  export NEOANKI_SYNC_FUZZ_STEPS="${NEOANKI_SYNC_FUZZ_STEPS:-200}"
  export NEOANKI_SYNC_CONTRACT_SEEDS="${NEOANKI_SYNC_CONTRACT_SEEDS:-32}"
  export NEOANKI_SYNC_CONTRACT_STEPS="${NEOANKI_SYNC_CONTRACT_STEPS:-40}"
fi

for setting in NEOANKI_SYNC_FUZZ_SEEDS NEOANKI_SYNC_FUZZ_STEPS NEOANKI_SYNC_FUZZ_SEED \
  NEOANKI_SYNC_CONTRACT_SEEDS NEOANKI_SYNC_CONTRACT_STEPS NEOANKI_SYNC_CONTRACT_SEED \
  NEOANKI_SYNC_CONTRACT_SEED_BASE; do
  value="${!setting:-}"
  if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$setting must be a nonnegative decimal integer." >&2
    exit 2
  fi
done

# Reject controls Swift would otherwise silently clamp or fail to parse. A
# requested reproduction seed must never quietly become a different campaign.
python3 - <<'PYTHON'
import os, sys
bounds = {
    "NEOANKI_SYNC_FUZZ_SEED": (0, 2**64 - 1),
    "NEOANKI_SYNC_CONTRACT_SEED": (0, 2**64 - 1),
    "NEOANKI_SYNC_CONTRACT_SEED_BASE": (0, 2**64 - 1),
    "NEOANKI_SYNC_CONTRACT_SEEDS": (1, 64),
    "NEOANKI_SYNC_CONTRACT_STEPS": (1, 200),
}
for name, (minimum, maximum) in bounds.items():
    raw = os.environ.get(name)
    if not raw:
        continue
    try:
        valid = minimum <= int(raw) <= maximum
    except ValueError:
        valid = False
    if not valid:
        print(f"{name} must be between {minimum} and {maximum}.", file=sys.stderr)
        sys.exit(2)
PYTHON

cd "$ROOT"
export NEOANKI_SYNC_CONTRACT_ARTIFACTS="${NEOANKI_SYNC_CONTRACT_ARTIFACTS:-$ROOT/.build/sync-contract-artifacts}"
if [[ "$CONTRACTS_ONLY" == 1 ]]; then
  swift test --filter SyncConvergenceContractTests
else
  # Existing codec/state-machine regressions remain alongside the stricter
  # automatic-delivery contracts. No test talks to live CloudKit.
  swift test --filter 'SyncConvergenceContractTests|SyncStateMachineTests|SyncMetadataStoreTests|SyncMergePolicyTests|OfflineFirstSyncServiceTests|CKSyncEngineTransportTests|LibraryZoneChangeFetcherTests|sqliteSyncAdapter|syncAdapter|initialMerge|linkedLibraries|itemTypeSyncEnvelope|syncMetadataStages|synchronized'
fi
