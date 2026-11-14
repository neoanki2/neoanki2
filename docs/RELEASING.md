---
title: Releasing NeoAnki2
description: Publish affected apps with one shared version and update the local Mac and paired iPhone.
audience: developer
parent: Developer Guide
permalink: /RELEASING/
---

# Releasing NeoAnki2

Merge the requested local changes into `main`, update a clean local `main`
checkout, then run the release command on the configured signing Mac:

```bash
./Scripts/release.sh
```

It uses that merged main revision, detects affected apps, verifies relevant code,
then builds and publishes the selected distributions and installs the latest iOS
version on the paired iPhone. The release agent also completes the local Mac
upgrade when applicable. It does not run broad UI
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

1. Requires the requested changes to be merged first. Commit local release input,
   push and merge its PRs using authenticated `gh`, then update a clean `main`
   checkout. A queued auto-merge is insufficient. The command checks that its
   checkout is clean, on `main`, and exactly matches remote `main`; a blocked
   merge stops the release before version reservation, signing or publication.
2. Records that `main` SHA, then atomically reserves the version tag and a draft
   release. Builds run from a
   detached worktree pinned to that source, so later edits cannot contaminate them.
3. Runs the headless test targets that depend on changed modules, once. A shared
   Core change can select many unit suites; docs-only work selects no app release.
4. Builds unsigned Store archives and the notarized universal Homebrew DMG in
   parallel. Store exports use disposable signing Keychains. Signing contexts are
   serialized because Keychain search lists are shared OS state.
5. Validates signed packages and uploads each selected Store binary once. It
   preserves current listing/screenshots, updates release notes/reviewer details,
   attaches the exact processed build, and submits with automatic release enabled.
   What's New is sent only for updates after that platform's first public release;
   Apple forbids the field for an initial release regardless of its version number.
   A superseded in-review build is withdrawn only when its replacement is ready.
6. Publishes the signed/notarized DMG and checksum and updates the official tap.
   iOS-only tracking releases do not replace GitHub's latest Mac download.
7. Saves per-channel progress after external operations and checks that its
   recorded main source remains in remote `main` before publishing. It never
   publishes an unmerged branch or bypasses branch protection.
8. Reports actual channel states and the checkpoint path. After Homebrew
   publication, the agent completes the release request by refreshing the tap
   and running `brew upgrade --cask neoanki2/tap/neoanki2` on this Mac. It verifies
   the installed version and signature, then launches NeoAnki2 exactly once,
   terminating the previous process if needed for a safe upgrade. The local
   library and settings are preserved. An iOS-only release with no newer Mac
   version skips this step. Local installation and Store availability are
   reported separately; Apple's review can still be pending.
9. Once all selected channels are published/submitted, the controller runs
   `./Scripts/deploy-iphone.sh` using its pinned source and the iOS channel's
   exact marketing version and build number. It signs with the saved Ad Hoc
   profiles, installs in place on the paired iPhone, and launches once. Both the
   app and widget versions are checked before installation. This preserves app
   data and does not require TestFlight or waiting for Store approval. Mac-only
   releases install the latest existing iOS version; they do not advance its
   version number. Every release requires this verified iPhone installation as
   well as the applicable local Mac upgrade before the agent reports completion.

Connect and unlock the paired iPhone with Developer Mode enabled before a release.
If several phones are available, select the intended target:

```bash
./Scripts/release.sh --device NAME_OR_IDENTIFIER
```

Missing devices, signing problems, and failed installs/launches block local
completion and return a nonzero exit status. Publication receipts remain intact.
`IPHONE_DEPLOY_*` telemetry is printed and retained in the release's
`iphone-N.log`; deployment and device receipts live in `iphone-N/`. Device details
stay in local receipts and are excluded from the public release checkpoint.

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

An unfinished iPhone update remains pending locally even after publication's
`complete: true` checkpoint. Connect the phone or resolve the reported signing
blocker, then run `./Scripts/release.sh --resume VERSION` (with `--device` when
needed). The normal release command also detects this pending local delivery.
Resuming local delivery skips completed publication and reuses a verified
successful deployment without another install or launch. If an install/launch
was interrupted or failed after its durable intent was recorded, the controller
stops for receipt inspection instead of automatically repeating the device
operation. `--status` includes this Mac's saved iPhone delivery state.

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

## Cleanup after a successful release

The release agent cleans disposable outputs after the controller records
`complete: true`, every selected channel is published or submitted, and the
local Mac upgrade and iPhone installation are verified. The local checkpoint must
show `local_iphone.status: installed` and retain the matching deployment receipt;
publication's `complete: true` flag alone is insufficient. Apple review may still
be pending. Older successfully completed releases can be cleaned in the same pass. Hold the
release lock and preserve recovery inputs for pending, failed, abandoned, or
uncertain uploads.

Keep release/platform checkpoints, local-upgrade and iPhone deployment/device
receipts, original validation and delivery logs, checksums, signing/notarization
evidence, and production debug symbols. Preserve dSYMs and symbol maps in a verified compressed archive first;
keep exact shipped executables when matching symbols are unavailable. Original
hash-referenced logs remain unchanged for resume validation.

Remove release-owned derived data, build caches, archives, exported binaries,
temporary tap clones, and clean pinned Git worktrees. Remove the deployment's
disposable app bundle and `DerivedData` only after its installation is verified.
Verify worktree revisions and inspect ignored files before removing generated
outputs. A local DMG can be removed once authenticated `gh` confirms its published asset digest matches
the release receipt. Keep the installed app, library/settings, saved credentials,
remote assets, unrelated worktrees, and shared development caches intact.
Record removed paths and reclaimed space in `cleanup.json` beside the retained
release receipt and report the cleanup result.

## Signing setup

Required checks and branch protections govern merging before release starts.
Confirm that GitHub reports the source PRs as merged, then run the controller
from the resulting clean `main` checkout. It does not request auto-merge after
publication. Old branch-built checkpoints cannot resume publication under this
policy: preserve their artifacts and published history, merge the changes, and
prepare a new release from `main` if app changes still need publication. Use
`--status` to inspect an older release without resuming it.

Saved inputs remain in `~/Library/Application Support/NeoAnki2 Signing/`.
`--signing-dir` and `--config` select another configured location. Keep all private
keys and API credentials outside the repository.

- iOS/Mac Store: `app-store-connect.json`, its referenced API key,
  `Apple-Distribution.cert.pem`, and `Apple-Distribution.key.pem`.
- Local iPhone delivery: also `AppleWWDRCAG3.cer`,
  `iOS-AdHoc.mobileprovision`, and `Widget-AdHoc.mobileprovision`, with the
  paired iPhone registered in both profiles.
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
python3 Scripts/test-deploy-iphone.py
python3 Scripts/test-release-ios.py
python3 Scripts/test-release-macos-app-store.py
```
