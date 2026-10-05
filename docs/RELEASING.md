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
seconds once the saved Apple signing material is configured.

## Run a release

Run this from the repository:

```bash
./Scripts/release.sh
```

The command performs the complete transaction without prompts:

1. Fetches and automatically integrates the current `main`, creating a
   `release/*` branch when invoked on `main`.
2. Stages every tracked and untracked, non-ignored local change and commits the
   exact tree. Existing local commits ahead of `main` are included too.
3. Derives the next `1.0.N` version from the latest published release.
4. Runs `Scripts/test-fast.sh` and the universal DMG build concurrently. The
   app is signed with Developer ID, provisioned for production CloudKit,
   submitted to Apple for notarization, stapled, and assessed by Gatekeeper.
5. Pushes with authenticated `gh`, creates or reuses a pull request, and checks
   that its head still matches the locally verified revision.
6. Attempts an immediate administrative merge after the local gates pass. If
   branch protection forbids bypass, it enables automatic merge when available
   and publishes the exact verified PR head while its exhaustive Test and
   Documentation workflows continue; those checks do not block the five-minute
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

## Required Apple signing

Mac releases require Developer ID signing, production CloudKit provisioning,
hardened runtime, and accepted Apple notarization. Local source installations
through `Scripts/install-app.sh` require the same signing and CloudKit
capabilities, but do not wait for notarization by default. Missing credentials, expired profiles, incorrect
capabilities, rejected notarization, or failed Gatekeeper assessment stop the
build before publication or replacement. There is no unsigned release fallback.

The default material directory is
`~/Library/Application Support/NeoAnki2 Signing/`. Override it with
`NEOANKI_SIGNING_DIR`. It contains:

- `Developer-ID-Application.cert.pem` and `Developer-ID-Application.key.pem`;
- `DeveloperIDG2CA.cer`;
- `Mac-DeveloperID.provisionprofile`, authorizing `com.neoanki2.app`,
  `iCloud.com.neoanki2.app`, production CloudKit, and production push;
- `app-store-connect.json`, with `key_id`, `issuer_id`, `private_key_path`, and
  `team_id`, plus the referenced App Store Connect API private key.

Run `python3 Scripts/sign-macos-app.py --check --sign-only` to validate local
signing inputs, or omit `--sign-only` to also validate notarization credentials.
Signing imports the saved material into a disposable Keychain and cleans it up;
it never requires unlocking the existing signing Keychain. Notarization uses
API authentication and does not prompt for Apple ID or Mac passwords.

The Release and Release candidate workflows use the same signer. Configure
repository secrets through authenticated `gh`: `APPLE_DEVELOPER_ID_P12_BASE64`,
`APPLE_DEVELOPER_ID_P12_PASSWORD`, `APPLE_DEVELOPER_ID_PROFILE_BASE64`,
`APPLE_DEVELOPER_ID_CHAIN_BASE64`, `APPLE_NOTARY_KEY_BASE64`,
`APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, and `APPLE_DEVELOPMENT_TEAM`.
The runner decodes them into a private temporary directory removed on exit.

`NEOANKI_INSTALL_SIGNED=0` is an explicit development-only option for local
unprovisioned bundles. The release packager always forces signing and notarization and rejects
`NEOANKI_RELEASE_SIGNED=0`. Local installs default to
`NEOANKI_INSTALL_NOTARIZE=0`; set it to `1` to require notarization for a local
installation too. Headless `swift build` and disposable UI-test bundles
continue to work without distribution credentials.

The packager saves `notarization.json` beside the DMG. Verify an existing bundle
with `python3 Scripts/sign-macos-app.py --verify /path/to/NeoAnki2.app`.
Add `--sign-only` to verify a local source build without a notarization ticket.
Homebrew casks preserve quarantine; they no longer remove it to bypass a missing
notarization ticket. Previously published builds retain their original signing
status, so inspect the selected release's notes.

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
dependencies. Apple notarization is an external gate and can exceed the budget;
the release must stop instead of shipping an unnotarized app. The value is not a claim that an internet outage can still produce a public
Homebrew release.

## Verification model

The fast path moves exhaustive CI off the critical path; it does not pretend
those jobs finish within five minutes. The release artifact is protected by:

- an exact automatic commit of the local tree;
- the complete headless fast suite before merge;
- a universal release build, Developer ID and production CloudKit verification,
  accepted notarization, stapling, Gatekeeper assessment, architecture check,
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
