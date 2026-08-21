---
title: Releasing NeoAnki2
description: Validate, package, attest, publish, and install a NeoAnki2 release.
audience: developer
parent: Developer Guide
permalink: /RELEASING/
---

# Releasing NeoAnki2

NeoAnki2 has one release path. Local preflight catches inexpensive failures;
GitHub first proves documentation integrity and the fast macOS UI journey, then
builds an immutable, provenance-attested candidate while the remaining
protected pull-request checks run. Promotion waits for both and is resumable
after any remote step.

## Run a release

Start from a clean `codex/*` feature branch based on current `main`. Put the
pull-request body in an ignored file such as `.build/release-pr.md`, then run:

```bash
./Scripts/release.sh \
  --title "Release change" \
  --body-file .build/release-pr.md
```

The command uses authenticated `gh` operations, runs the supported local build
and fast tests before the first push, creates or reuses the pull request, waits
for any required CI screenshot promotion, and reconciles the promoted
revision's automatic workflows. Candidate packaging starts only after the
**Documentation and screenshot gate** and **Fast functional UI journeys** pass.
The command then waits for both the attested candidate and all required
branch-protection checks, merges, publishes, updates the official Homebrew tap
from the candidate manifest, and upgrades `/Applications/NeoAnki2.app`, verifies
it, and launches that exact app once.

For UI-bearing changes, run the targeted journey and the complete local UI
suite before invoking the release command:

```bash
./Scripts/run-ui-tests.sh FastFunctionalJourneyTests/testRelevantJourney
./Scripts/run-ui-tests.sh
```

Do not push a UI-bearing release when local UI automation is unavailable. The
command's headless preflight is deliberately not represented as UI proof.

“Release” is deliberately the complete transaction. Use `--no-install` or
`--no-launch` only for an explicitly requested narrower operation. NeoAnki2
remains available until the replacement is ready.

When screenshot-backed sources changed, the command waits for the isolated CI
capture workflow to generate, validate, and commit fresh documentation images
to the pull-request branch. Candidate packaging and protected checks use that
promoted revision. There is no release path that accepts stale screenshots.

GitHub may mark automatic `pull_request` workflows on a screenshot-bot commit
as `action_required`. The release command approves only the repository's known
Documentation, Documentation screenshots, and Test workflows when they belong
to the exact PR head and were triggered by `github-actions[bot]`. Unknown runs
stop the transaction for review. If automatic Documentation or Test runs are
absent, the command dispatches exact-head fallbacks. It never runs both paths
deliberately.

## Resume safely

Every remote phase is idempotent. If the command is interrupted or a check must
be rerun, resume without repeating completed work:

```bash
./Scripts/release.sh --pr NUMBER
```

If the matching clean local PR branch contains committed corrections after a
failed gate, resume validates and pushes that ahead-only head before it
reconciles workflows. A divergent branch is rejected; do not force-push or
manually recreate release phases.

The command reuses a matching workflow run or draft candidate, waits for
required checks, reconciles recoverable bot-owned workflow approvals, and skips
an already completed merge, publication, tap update, or verified installation.
A stale PR, changed source revision, unknown approval request, conflicting
version/checksum, or mismatched manifest stops the release.

## Timing and failure telemetry

Every invocation prints stable `RELEASE_*` fields on exit, including success or
failure, the phase where it stopped, total elapsed time, and completed local
preflight, screenshot, reconciliation, candidate-gate, and candidate durations.
Promotion prints complementary `SHIP_*` fields. Preserve these lines when
auditing a slow or interrupted release; GitHub workflow duration and runner
consumption are separate measurements because jobs overlap.

When an exact screenshot workflow already ended in a retryable infrastructure
failure, a resumed transaction starts one new attempt of that same run and
waits for GitHub to expose it before continuing. Approval-required or otherwise
unknown conclusions are not retried automatically.

## Invariants

- `release-candidate.json` is the only source for version, artifact name,
  revision, and checksum. The Homebrew cask is generated from it.
- The candidate schema always includes the pull-request number and exact head,
  base, and tree revisions. Local pre-push candidate formats do not exist.
- Standard PR checks are the acceptance authority. Candidate packaging waits
  for documentation and fast UI success, then overlaps the slower remaining
  checks without duplicating them.
- Workflow concurrency is keyed by repository and source branch for both
  `pull_request` and dispatched runs, so a new revision cancels superseded Test
  and Documentation work promptly.
- NeoAnki2 remains available during local checks, CI, merge, publication, tap
  update, and Homebrew refresh. It is stopped only immediately before an actual
  app replacement.
- A previously running app is launched once from the absolute path
  `/Applications/NeoAnki2.app`; the running executable path is verified. Never
  use `open -a NeoAnki2`, because Launch Services may select a development app.
- App replacement first requests a normal application quit. If the verified
  app process remains after ten seconds, the script sends `SIGTERM` and waits a
  second grace period. It never uses `SIGKILL` and refuses to signal an
  unexpected executable path.
- A completed release never fails merely because it exceeded an arbitrary time
  target. Phase durations are telemetry, not correctness gates.

## Recovery-only workflow

The legacy **Release** GitHub workflow builds from a tested `main` revision and
is retained only for recovery when the candidate path cannot be used. Do not run
it alongside a normal candidate release. The tap's scheduled updater is also a
repair mechanism, not part of normal promotion.

## Developer ID path

Official CloudKit-capable artifacts are produced by the headless
`Xcode/NeoAnkiMac.xcodeproj` target. A Developer ID certificate, CloudKit
provisioning profile, and `notarytool` keychain profile are external
prerequisites. `Scripts/build-release-artifact.sh` selects the signed archive
path when `NEOANKI_RELEASE_SIGNED=1`; the default contributor candidate remains
ad-hoc signed so local development does not require private credentials.
