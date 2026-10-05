# A retry is for an incomplete XCTest operation, never a completed app assertion
# or accessibility finding. Keep the exact messages; a generic timeout may be
# an app hang and must fail without a retry.
def infrastructure_kind:
  if type != "object" or (.failureText | type) != "string" then null
  elif (.failureText | contains("test runner exited with code")) then "runner"
  elif (.failureText | contains("Audit failed to complete in time")
        or contains("Timed out while running accessibility audit with config:")) then "audit"
  elif (.failureText | contains("Failed to get launch progress")) then "launch"
  elif (.failureText | test("^Failed to get background assertion for target app with pid [0-9]+: Timed out while acquiring background assertion\\.$")) then "background"
  else null
  end;

(.testFailures // []) as $raw_failures
| (if ($raw_failures | type) == "array" then ($raw_failures | flatten)
   else [$raw_failures] end) as $failures
| ($failures | map(infrastructure_kind)) as $kinds
| ($failures | length) as $count
| ($count > 0 and ($kinds | all(. != null))) as $all_infrastructure
| (.totalTestCount == 0 and $count == 0
   and (.passedTests // 0) == 0 and (.failedTests // 0) == 0
   and (.skippedTests // 0) == 0) as $zero_started
| {
    retryable: ($all_infrastructure or $zero_started),
    all_failures_infrastructure: $all_infrastructure,
    failure_count: $count,
    runner_exit_failure: ($kinds | any(. == "runner")),
    accessibility_audit_timeout: ($kinds | any(. == "audit")),
    app_launch_progress_timeout: ($kinds | any(. == "launch")),
    app_background_assertion_timeout: ($kinds | any(. == "background")),
    zero_tests_no_failures: $zero_started
  }
