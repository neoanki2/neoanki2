---
name: release
description: Release current NeoAnki2 local changes to GitHub and the official Homebrew tap, install and verify the app, and launch the exact installed path within a five-minute SLO. Use when asked to release, ship, publish, merge-and-release, update the Homebrew cask, install a new NeoAnki2 version, or resume a release.
---

# Release NeoAnki2

Use the repository command; do not reconstruct its GitHub, tap, or installation
steps manually.

## Default: local changes to Brew in five minutes

When the user says `release`, immediately run:

```bash
./Scripts/release.sh
```

The dirty working tree is intentional release input. Do not ask for a title,
body, confirmation, clean tree, or advance preparation. The command stages and
commits all non-ignored local changes, includes already committed work ahead of
`main`, and creates a release branch automatically when invoked on `main`.

The command runs the complete headless fast suite and universal artifact build
in parallel. It pushes with authenticated `gh`, creates or reuses a PR,
attempts to merge the exact locally verified revision, publishes the
DMG/checksum/manifest, updates `neoanki2/homebrew-tap`, upgrades the cask,
verifies the installed version/revision/signature, and performs at most one
exact-path launch. The merge automatically starts exhaustive Test and
Documentation workflows in the background; never wait for those hosted jobs on
the five-minute critical path and do not run the full UI suite locally.

Keep NeoAnki2 running until the command's just-in-time Homebrew replacement.
Do not separately stop, install, or launch the app.

## Explicit slower recovery

Only when the user explicitly waives the five-minute requirement and requests
pre-publication hosted validation, run the legacy path:

```bash
./Scripts/release.sh --verified \
  --title "Concise release title" \
  --body-file .build/release-pr.md
```

Resume it with `./Scripts/release.sh --verified --pr NUMBER`. That path may wait
for protected checks, screenshot promotion, hosted UI matrices, and the
GitHub-attested candidate.

## Guardrails

- Use authenticated `gh` only; never use a GitHub connector.
- Do not manually edit the Homebrew tap or infer a checksum.
- Do not bypass either local fast gate even when the build artifact succeeds.
- Do not start publication when the command reports insufficient remaining
  budget.
- Never use `SIGKILL`, `open -a NeoAnki2`, or a second launch attempt.
- If a local gate fails, correct the branch and run the default command again.
- If a remote phase partially completes, inspect the emitted phase and resume
  without deleting a valid release or overwriting a divergent branch.

## Report

Return the PR URL, release tag and URL, source revision, official tap version,
installed version and embedded revision, signature result, exact running app
path when launched, and the `FAST_RELEASE_*` timing fields. If blocked, name
the exact phase and invariant that stopped the command.
