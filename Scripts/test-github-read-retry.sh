#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/neoanki2-github-retry-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT
mkdir -p "$TEST_DIRECTORY/bin"

cat > "$TEST_DIRECTORY/bin/gh" <<'EOF'
#!/usr/bin/env bash
attempt="$(cat "$MOCK_ATTEMPTS" 2>/dev/null || echo 0)"
attempt="$((attempt + 1))"
echo "$attempt" > "$MOCK_ATTEMPTS"
if [ "$attempt" -le "$MOCK_FAILURES" ]; then
  echo '{"message":"Server Error"}'
  echo 'gh: Server Error (HTTP 502)' >&2
  exit 1
fi
echo '{"check_runs":[{"conclusion":"success"}]}'
EOF
cat > "$TEST_DIRECTORY/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_DIRECTORY/bin/gh" "$TEST_DIRECTORY/bin/sleep"
export PATH="$TEST_DIRECTORY/bin:$PATH"
export MOCK_ATTEMPTS="$TEST_DIRECTORY/attempts"

export MOCK_FAILURES=1
output="$(bash "$ROOT/Scripts/read-github-with-retry.sh" api example 2>"$TEST_DIRECTORY/retry.log")"
[ "$output" = '{"check_runs":[{"conclusion":"success"}]}' ]
[ "$(cat "$MOCK_ATTEMPTS")" -eq 2 ]

rm "$MOCK_ATTEMPTS"
export MOCK_FAILURES=10
if bash "$ROOT/Scripts/read-github-with-retry.sh" api example >"$TEST_DIRECTORY/output" 2>"$TEST_DIRECTORY/failure.log"; then
  echo "An exhausted GitHub read must fail." >&2
  exit 1
fi
[ ! -s "$TEST_DIRECTORY/output" ]
[ "$(cat "$MOCK_ATTEMPTS")" -eq 5 ]
echo "GitHub read retries preserve valid JSON and fail after five attempts."
