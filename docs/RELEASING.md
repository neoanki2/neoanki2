---
title: Releasing NeoAnki2
description: Publish affected apps to iOS, the Mac App Store, and Homebrew with one shared version.
audience: developer
parent: Developer Guide
permalink: /RELEASING/
---

# Releasing NeoAnki2

Run one command from the repository on the configured signing Mac:

```bash
./Scripts/release.sh
```

It includes current local changes, detects affected apps, verifies relevant code,
then builds and publishes the selected distributions. It does not run broad UI
journeys, physical acceptance, screenshot capture, or browser review ceremonies.
This replaces the separate Homebrew/iOS/Mac Store release processes. The old
`release-fast.sh`, `release-ios.sh`, `release-macos-app-store.sh`,
`ship-release.sh`, and candidate build/publish entry points are retired. The
independent GitHub Release workflow and candidate publisher were removed so they
cannot allocate conflicting versions. The optional Store diagnostics workflow
does not publish app releases.

## Which apps get released

| Changed inputs | Published channels |
| --- | --- |
| iOS app, widget, mobile UI, iOS project or listing | iOS App Store |
| Mac app, local API, Mac packaging/project/listing | Mac App Store and Homebrew |
| Shared library, CloudKit, shared UI, scheduling/Core, package dependencies | All affected apps through their dependency graph |
| Documentation, tests, release controller, unused CLI tools | No app publication |

The planner reads SwiftPM dependency closures and the iOS application's actual
Xcode package products, including its direct CloudKit dependency. It compares
content against each channel's last published/submitted inputs. Added, removed,
and renamed files count; an iOS-only release never advances the Mac baseline.
Build/packaging inputs count for their platform. Package manifest changes
conservatively affect both apps. Optional diagnostic preview:

```bash
./Scripts/release.sh --plan
./Scripts/release.sh --plan --offline
```

The normal preview reads the canonical release checkpoint and current Apple
versions without committing, building, uploading, or publishing. Offline preview
uses the checked-in migration baseline and is only an estimate.

## One version sequence

A release reserves one marketing version and one increasing build number for
**every selected artifact**, including the iOS widget. The default is the next
patch above all GitHub reservations and both Store version histories. The build
counter also exceeds prior Mac, iOS, and Homebrew builds. A specific newer version
can be chosen with `--version 1.1.0`.

The migration baseline is Homebrew **1.0.319**, iOS **1.0.2 (3)**, and Mac Store
**1.0.1 (5)**, all sourced from `3c68267`. The next release therefore starts at
**1.0.320 (320)** unless another version has since been reserved.

| Example release | iOS | Mac Store | Homebrew |
| --- | --- | --- | --- |
| Shared change | 1.0.320 | 1.0.320 | 1.0.320 |
| Next change is iOS-only | 1.0.321 | stays 1.0.320 | stays 1.0.320 |
| Next change is Mac-only | stays 1.0.321 | 1.0.322 | 1.0.322 |

Untouched apps skip release numbers. Shared numbering does not mean rebuilding an
unchanged app. Homebrew and Mac Store always receive the same version when Mac
changes, although their bundle IDs, signatures, sandboxing, and binaries differ.

## What the command does

1. Captures local changes on a fresh `release/*` branch, integrates current
   `main`, pushes with `gh` authentication, and creates a PR for the exact source.
2. Atomically reserves the version tag and a draft release. Builds run from a
   detached worktree pinned to that source, so later edits cannot contaminate them.
3. Runs the headless test targets that depend on changed modules, once. A shared
   Core change can select many unit suites; docs-only work selects no app release.
4. Builds unsigned Store archives and the notarized universal Homebrew DMG in
   parallel. Store exports use disposable signing Keychains. Signing contexts are
   serialized because Keychain search lists are shared OS state.
5. Validates signed packages and uploads each selected Store binary once. It
   preserves current listing/screenshots, updates release notes/reviewer details,
   attaches the exact processed build, and submits with automatic release enabled.
   A superseded in-review build is withdrawn only when its replacement is ready.
6. Publishes the signed/notarized DMG and checksum and updates the official tap.
   iOS-only tracking releases do not replace GitHub's latest Mac download.
7. Saves per-channel progress after external operations. It requests PR auto-merge
   without waiting for exhaustive hosted checks or bypassing branch protection.
8. Reports actual channel states and the checkpoint path. Publication does not
   install apps or interrupt the running desktop. Upgrade locally when wanted
   with `brew upgrade --cask neoanki2/tap/neoanki2`.

“Together” means one coordinated command and one source/version assignment.
Homebrew can become available immediately; Apple controls processing, review,
and Store availability. Submitted, in-review, approved/available, and failed
states are never treated as interchangeable. There is no artificial five-minute
promise for Apple's external work.

## Progress and recovery

Receipts, immutable source, artifacts, and logs live in
`.build/releases/VERSION/`. The GitHub release asset `release-state.json` records
canonical progress and per-channel content baselines. Completed channels are
retained when another channel is still processing or fails.

```bash
./Scripts/release.sh --status
./Scripts/release.sh --resume 1.0.320
```

The normal command resumes a pending release when current app inputs still match.
It waits up to ten minutes for Apple processing/cancellation; `--wait-seconds 0`
returns immediately with the resume command. Apple review itself is not waited
on. Another version is never allocated just because processing is slow.

If code needs fixing after a failed local gate, stop that reserved release before
starting a new source/version:

```bash
./Scripts/release.sh --abandon 1.0.320
# Fix the cause, then run ./Scripts/release.sh again.
```

Abandonment preserves history, evidence, and any already published channel.
Never delete a valid release, force-push a reserved version, rerun an unchanged
failed check, or retry an uncertain upload. An upload interrupted after delivery
is reconciled by exact version/build and saved upload identity; if Apple has not
yet exposed it, the command waits rather than sending again. Inspect the receipt
and delivery log before abandoning or manually recovering an upload.

Apple's version can become editable while its parent submission is still
`CANCELING`. The controller waits for that parent to finish before replacement;
removed review items are not reused. Rejected binaries, unresolved review items,
missing listing/account requirements, and conflicting release identities stop
with a concrete error. Read Apple's actual written rejection before remediation;
do not manufacture review approvals or acceptance evidence.

The same configured Mac and retained local logs are the normal resume path.
Keep the receipt directory until release completion. Manual publication outside
this controller requires a deliberate, evidence-backed baseline migration.

## Signing setup

Saved inputs remain in `~/Library/Application Support/NeoAnki2 Signing/`.
`--signing-dir` and `--config` select another configured location. Keep all private
keys and API credentials outside the repository.

- iOS/Mac Store: `app-store-connect.json`, its referenced API key,
  `Apple-Distribution.cert.pem`, and `Apple-Distribution.key.pem`.
- Mac Store: also `Mac-Installer-Distribution.cert.pem` and
  `Mac-Installer-Distribution.key.pem`.
- Homebrew: `Developer-ID-Application.cert.pem`, its key,
  `DeveloperIDG2CA.cer`, and `Mac-DeveloperID.provisionprofile`, plus accepted Apple
  notarization through the saved App Store Connect API identity.

The existing platform adapters still validate profiles, app/widget privacy
manifests, universal Mac architectures, signatures, production CloudKit, package
identity, and export/upload receipts. Their Python modules are internal build
adapters; their former independent publishing CLIs are retired. No release
fallback removes quarantine, weakens signing, asks for a Keychain password, or
represents unperformed checks as passes.

Set customer-facing What's New text without a separate body file:

```bash
./Scripts/release.sh --notes "Fixed iCloud review synchronization across devices."
```

Release tooling can be verified without contacting Apple/GitHub or publishing:

```bash
python3 Scripts/test-release.py
python3 Scripts/test-release-ios.py
python3 Scripts/test-release-macos-app-store.py
```
