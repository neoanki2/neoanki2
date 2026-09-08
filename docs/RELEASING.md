---
title: Releasing NeoAnki2
description: Release current local changes through Homebrew within five minutes.
audience: developer
parent: Developer Guide
permalink: /RELEASING/
---

# Releasing NeoAnki2

NeoAnki2's default release path starts with the current local working tree and
targets a verified installation from the official Homebrew tap within 300
seconds. It does not require advance preparation.

## Run a release

Run this from the repository:

```bash
./Scripts/release.sh
```

The command performs the complete transaction without prompts:

1. Fetches and automatically integrates the current `main`, creating a
   `codex/release-*` branch when invoked on `main`.
2. Stages every tracked and untracked, non-ignored local change and commits the
   exact tree. Existing local commits ahead of `main` are included too.
3. Derives the next `1.0.N` version from the latest published release.
4. Runs `Scripts/test-fast.sh` and the universal DMG build concurrently.
5. Pushes with authenticated `gh`, creates or reuses a pull request, and checks
   that its head still matches the locally verified revision.
6. Administratively merges that exact revision after the local gates pass.
   The merge starts the exhaustive Test and Documentation workflows on `main`;
   those checks are deliberately post-release and do not block the five-minute
   path.
7. Publishes the DMG, checksum, and schema-v2 release manifest, updates the
   official `neoanki2/homebrew-tap`, upgrades the cask, verifies the installed
   version, revision, and signature, and launches `/Applications/NeoAnki2.app`
   exactly once when appropriate.

An optional title can be supplied without creating a body file:

```bash
./Scripts/release.sh --title "Fix repeated Again behavior"
```

The app remains open during compilation, tests, upload, and tap publication.
If it is running, the command requests a normal quit only immediately before
Homebrew replaces it and relaunches the exact installed path once afterward.

## Five-minute budget

`NEOANKI_RELEASE_SLO_SECONDS` defaults to `300`. The measured cold universal
build is roughly 151 seconds on the release host; the fast suite overlaps it.
Push and pull-request setup also overlap the local work. Before irreversible
remote publication and before app replacement, the command requires enough
remaining budget to finish that phase safely.

Every exit prints stable `FAST_RELEASE_*` telemetry for the phase, build, test,
remote, install, total duration, and SLO result. A gate failure leaves the
created commit and pull request available for correction, but does not merge,
publish, change the tap, or replace the app.

Network and GitHub availability cannot be made deterministic by a local
script. The 300-second value is an enforced operational SLO under available
dependencies, not a claim that an internet outage can still produce a public
Homebrew release.

## Verification model

The fast path moves exhaustive CI off the critical path; it does not pretend
those jobs finish within five minutes. The release artifact is protected by:

- an exact automatic commit of the local tree;
- the complete headless fast suite before merge;
- a universal release build, code-signature verification, architecture check,
  and SHA-256 manifest before publication;
- exact PR-head and latest-version race checks;
- automatic exhaustive Test and Documentation runs caused by the merge to
  `main`;
- exact Homebrew version, embedded Git revision, and signature verification.

This is an intentionally optimistic release policy. A product that requires
all hosted UI matrices and GitHub provenance attestation before public
availability cannot also guarantee a five-minute release from unbuilt local
changes. NeoAnki2 keeps that slower policy as an explicit recovery option.

## Explicit verified path

The former protected-check and attested-candidate flow remains available when
the five-minute requirement is waived:

```bash
./Scripts/release.sh --verified \
  --title "Release change" \
  --body-file .build/release-pr.md
```

Resume that path with:

```bash
./Scripts/release.sh --verified --pr NUMBER
```

It waits for screenshot promotion, protected checks, hosted UI matrices, and
the GitHub-built attested candidate before merging and installing. It is not
the default `release` behavior.

## Invariants

- The default command consumes local changes; a dirty worktree is input, not a
  blocker.
- The artifact is built only after those changes are committed, so the
  embedded revision and manifest identify the exact released tree.
- Local fast verification and packaging run concurrently and neither is
  skipped.
- No hosted check, runner queue, or screenshot job is awaited on the fast
  path. Full UI coverage runs automatically after the merge.
- The tap checksum is generated from the local artifact and never typed by a
  person.
- NeoAnki2 is never stopped before an actual Homebrew replacement.
- The script never uses `SIGKILL` or `open -a NeoAnki2` and never attempts a
  second GUI launch.
