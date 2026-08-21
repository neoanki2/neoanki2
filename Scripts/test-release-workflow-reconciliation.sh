#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/neoanki2-release-reconcile-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT

MOCK_DIRECTORY="$TEST_DIRECTORY/bin"
MOCK_LOG="$TEST_DIRECTORY/gh.log"
mkdir -p "$MOCK_DIRECTORY"

cat > "$MOCK_DIRECTORY/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >> "$MOCK_LOG"
case "$1 $2" in
  "pr view")
    echo "$MOCK_HEAD"
    ;;
  "api --paginate")
    if grep -q '/approve' "$MOCK_LOG" 2>/dev/null; then
      echo "${MOCK_RUNS_AFTER_APPROVAL:-$MOCK_RUNS}"
    else
      echo "$MOCK_RUNS"
    fi
    ;;
  "api --method")
    echo '{}'
    ;;
  "workflow run")
    ;;
  "run view")
    if [ -f "${MOCK_RERUN_MARKER:-/nonexistent}" ]; then
      printf '2\tin_progress\t\n'
    else
      printf '1\tcompleted\t%s\n' "${MOCK_RUN_CONCLUSION:-failure}"
    fi
    ;;
  "run rerun")
    touch "$MOCK_RERUN_MARKER"
    ;;
  "run watch")
    exit "${MOCK_WATCH_EXIT_STATUS:-0}"
    ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$MOCK_DIRECTORY/gh"

run_reconcile() {
  PATH="$MOCK_DIRECTORY:$PATH" \
  MOCK_LOG="$MOCK_LOG" \
  RELEASE_RECONCILE_MAX_ATTEMPTS="${RELEASE_RECONCILE_MAX_ATTEMPTS:-1}" \
  RELEASE_RECONCILE_SLEEP_SECONDS=0 \
    "$ROOT/Scripts/reconcile-release-workflows.sh" \
      --repo neoanki2/neoanki2 \
      --pr 70 \
      --head abc123 \
      --branch codex/example \
      --base def456
}

assert_log_absent() {
  local pattern="$1"
  if grep -q "$pattern" "$MOCK_LOG"; then
    echo "Unexpected mock gh invocation matching: $pattern" >&2
    exit 1
  fi
}

known_run() {
  local id="$1"
  local path="$2"
  local conclusion="$3"
  printf '%s' "{\"id\":$id,\"event\":\"pull_request\",\"conclusion\":$conclusion,\"status\":\"completed\",\"actor\":{\"login\":\"github-actions[bot]\"},\"path\":\"$path\",\"pull_requests\":[{\"number\":70}]}"
}

echo "==> Approves only known bot workflows for the exact PR head"
: > "$MOCK_LOG"
export MOCK_HEAD=abc123
export RELEASE_RECONCILE_MAX_ATTEMPTS=2
SCREENSHOT_ACTION_REQUIRED="$(known_run 11 .github/workflows/docs-screenshots.yml '"action_required"')"
DOCS_ACTION_REQUIRED="$(known_run 12 .github/workflows/docs-pages.yml '"action_required"')"
TEST_ACTION_REQUIRED="$(known_run 13 .github/workflows/test.yml '"action_required"')"
MOCK_RUNS="$(jq -cn \
  --argjson screenshots "$SCREENSHOT_ACTION_REQUIRED" \
  --argjson docs "$DOCS_ACTION_REQUIRED" \
  --argjson test "$TEST_ACTION_REQUIRED" \
  '{workflow_runs:[$screenshots,$docs,$test]}')"
export MOCK_RUNS
SCREENSHOT_APPROVED="$(known_run 11 .github/workflows/docs-screenshots.yml null)"
DOCS_APPROVED="$(known_run 12 .github/workflows/docs-pages.yml null)"
TEST_APPROVED="$(known_run 13 .github/workflows/test.yml null)"
MOCK_RUNS_AFTER_APPROVAL="$(jq -cn \
  --argjson screenshots "$SCREENSHOT_APPROVED" \
  --argjson docs "$DOCS_APPROVED" \
  --argjson test "$TEST_APPROVED" \
  '{workflow_runs:[$screenshots,$docs,$test]}')"
export MOCK_RUNS_AFTER_APPROVAL
run_reconcile >/dev/null
test "$(grep -c '/approve' "$MOCK_LOG")" -eq 3
assert_log_absent '^workflow run'

echo "==> Dispatches exact-head fallbacks only when automatic runs are absent"
: > "$MOCK_LOG"
export RELEASE_RECONCILE_MAX_ATTEMPTS=1
export MOCK_RUNS='{"workflow_runs":[]}'
unset MOCK_RUNS_AFTER_APPROVAL
run_reconcile >/dev/null
grep -q '^workflow run docs-pages.yml .*base_ref=def456' "$MOCK_LOG"
grep -q '^workflow run test.yml ' "$MOCK_LOG"

echo "==> Refuses to approve an unrecognized action-required workflow"
: > "$MOCK_LOG"
DOCS_APPROVED="$(known_run 12 .github/workflows/docs-pages.yml null)"
TEST_APPROVED="$(known_run 13 .github/workflows/test.yml null)"
UNKNOWN_ACTION_REQUIRED='{"id":99,"event":"pull_request","conclusion":"action_required","actor":{"login":"someone-else"},"path":".github/workflows/unknown.yml","pull_requests":[{"number":70}]}'
MOCK_RUNS="$(jq -cn \
  --argjson docs "$DOCS_APPROVED" \
  --argjson test "$TEST_APPROVED" \
  --argjson unknown "$UNKNOWN_ACTION_REQUIRED" \
  '{workflow_runs:[$docs,$test,$unknown]}')"
export MOCK_RUNS
if run_reconcile >"$TEST_DIRECTORY/unrecognized.out" 2>&1; then
  echo "Expected unrecognized action-required workflow to fail." >&2
  exit 1
fi
grep -q 'Unrecognized action-required workflows need manual review' \
  "$TEST_DIRECTORY/unrecognized.out"
assert_log_absent '/approve'
assert_log_absent '^workflow run'

echo "==> Stops if the PR head changes during reconciliation"
: > "$MOCK_LOG"
export MOCK_HEAD=moved456
export MOCK_RUNS='{"workflow_runs":[]}'
if run_reconcile >"$TEST_DIRECTORY/moved.out" 2>&1; then
  echo "Expected changed PR head to fail." >&2
  exit 1
fi
grep -q 'moved from abc123 to moved456' "$TEST_DIRECTORY/moved.out"
assert_log_absent '/approve'
assert_log_absent '^workflow run'

echo "==> Retries a failed exact workflow run before watching it"
: > "$MOCK_LOG"
MOCK_RERUN_MARKER="$TEST_DIRECTORY/rerun-started"
rm -f "$MOCK_RERUN_MARKER"
export MOCK_RERUN_MARKER MOCK_RUN_CONCLUSION=failure
PATH="$MOCK_DIRECTORY:$PATH" \
MOCK_LOG="$MOCK_LOG" \
RELEASE_WORKFLOW_RERUN_MAX_ATTEMPTS=1 \
RELEASE_WORKFLOW_RERUN_SLEEP_SECONDS=0 \
  "$ROOT/Scripts/watch-release-workflow.sh" \
    --repo neoanki2/neoanki2 --run 123 --label Screenshots >/dev/null
grep -q '^run rerun 123 --repo neoanki2/neoanki2 --failed$' "$MOCK_LOG"
grep -q '^run watch 123 --repo neoanki2/neoanki2 --exit-status$' "$MOCK_LOG"

echo "==> Refuses to retry an approval-required workflow run"
: > "$MOCK_LOG"
rm -f "$MOCK_RERUN_MARKER"
export MOCK_RUN_CONCLUSION=action_required
if PATH="$MOCK_DIRECTORY:$PATH" \
  MOCK_LOG="$MOCK_LOG" \
  RELEASE_WORKFLOW_RERUN_MAX_ATTEMPTS=1 \
  RELEASE_WORKFLOW_RERUN_SLEEP_SECONDS=0 \
    "$ROOT/Scripts/watch-release-workflow.sh" \
      --repo neoanki2/neoanki2 --run 124 --label Screenshots \
      >"$TEST_DIRECTORY/action-required.out" 2>&1; then
  echo "Expected approval-required workflow retry to fail." >&2
  exit 1
fi
grep -q 'requires approval; refusing an automatic retry' \
  "$TEST_DIRECTORY/action-required.out"
assert_log_absent '^run rerun'

echo "Release workflow reconciliation tests passed."
