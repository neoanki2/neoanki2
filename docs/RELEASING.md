---
title: Releasing NeoAnki2
description: Validate, package, attest, publish, and install a NeoAnki2 release.
audience: developer
parent: Developer Guide
permalink: /RELEASING/
---

# Releasing NeoAnki2

NeoAnki2 has one release path. Local preflight catches inexpensive failures;
GitHub builds an immutable, provenance-attested candidate while the protected
pull-request checks run. Promotion waits for both and is resumable after any
remote step.

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
for any required CI screenshot promotion, dispatches the **Release candidate**
workflow for the resulting revision, and waits for both the attested candidate
and required branch-protection checks. It then merges, publishes, updates the
official Homebrew tap from the candidate manifest, and upgrades
`/Applications/NeoAnki2.app`, verifies it, and launches that exact app once.

“Release” is deliberately the complete transaction. Use `--no-install` or
`--no-launch` only for an explicitly requested narrower operation. NeoAnki2
remains available until the replacement is ready.

When screenshot-backed sources changed, the command waits for the isolated CI
capture workflow to generate, validate, and commit fresh documentation images
to the pull-request branch. Candidate packaging and protected checks use that
promoted revision. There is no release path that accepts stale screenshots.

## Resume safely

Every remote phase is idempotent. If the command is interrupted or a check must
be rerun, resume without repeating completed work:

```bash
./Scripts/release.sh --pr NUMBER
```

The command reuses a matching workflow run or draft candidate, waits for
required checks, and skips an already completed merge, publication, tap update,
or verified installation. A stale PR, changed source revision, conflicting
version/checksum, or mismatched manifest stops the release.

## Invariants

- `release-candidate.json` is the only source for version, artifact name,
  revision, and checksum. The Homebrew cask is generated from it.
- The candidate schema always includes the pull-request number and exact head,
  base, and tree revisions. Local pre-push candidate formats do not exist.
- Standard PR checks are the acceptance authority. Candidate packaging runs in
  parallel and does not duplicate unit, documentation, or UI jobs.
- NeoAnki2 remains available during local checks, CI, merge, publication, tap
  update, and Homebrew refresh. It is stopped only immediately before an actual
  app replacement.
- A previously running app is launched once from the absolute path
  `/Applications/NeoAnki2.app`; the running executable path is verified. Never
  use `open -a NeoAnki2`, because Launch Services may select a development app.
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
